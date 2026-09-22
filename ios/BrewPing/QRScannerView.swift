import SwiftUI
import AVFoundation

/// 扫码页：扫描 Mac 端菜单栏弹窗里那张 `brewping://pair?...` 二维码。
///
/// 为什么用 `AVCaptureSession` 而不是 VisionKit 的 `DataScannerViewController`：
///  - 系统组件在模拟器/不支持机型上直接不可用，且 UI 不可控（配色、提示、扫描框都改不了）；
///  - 配对场景需要明确的"对准 Mac 上的二维码"引导与自定义取景框，自建更合适。
///
/// 扫到内容后**不在这里发起配对**，只把字符串回抛给调用方（配对表单），
/// 由表单统一决定怎么解析 / 填充，保持"扫码"与"配对"两件事解耦。
struct QRScannerView: View {
    /// 扫到二维码内容时回调（通常是 `brewping://pair?...` 或 6 位数字码）。
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraError: String?
    /// 相机错误是否属于「权限被拒」—— 只有这种情况才给「打开系统设置」出口
    /// （无相机 / 不支持是设备能力问题，去设置里也解决不了）。
    @State private var cameraDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                if let cameraError {
                    unavailableView(cameraError)
                } else {
                    QRCaptureRepresentable(
                        onScanned: onScanned,
                        onError: {
                            cameraError = $0
                            cameraDenied = $1
                        }
                    )
                    .ignoresSafeArea()
                    reticle
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// 取景框：四角标记 + 一句引导，帮助用户对准 Mac 屏幕上的二维码。
    private var reticle: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: 240, height: 240)
            Text("Point at the QR code shown in \(BrewPingConfig.macAppName) on your Mac.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            Spacer()
        }
        // 白色取景框贴在相机画面上，需要深色底衬托文字；用半透明黑而不是渐变。
        .background(Color.black.opacity(0.25).ignoresSafeArea())
    }

    /// 无法扫码时的降级视图（模拟器无相机 / 权限被拒 / 设备不支持）。
    /// 权限被拒时附「打开系统设置」—— 被拒后系统不会再弹框，这是唯一恢复途径
    /// （5.1.1(iv)：拒绝要在功能现场得到清晰说明与出路，且不影响手动输码配对）。
    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            if cameraDenied {
                Button {
                    PermissionCenter.openSystemSettings()
                } label: {
                    Label(L("Open Settings"), systemImage: "gear")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.bpPrimary)
            }
            Text("You can still enter the 6-digit pairing code manually.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }
}

/// `AVCaptureSession` 的 SwiftUI 包装。
private struct QRCaptureRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    /// 相机错误回调。第二个参数：是否属于「权限被拒」（决定扫码页要不要给
    /// 「打开系统设置」出口；无相机 / 不支持不是权限问题，给了也没用）。
    let onError: (String, Bool) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScanned = onScanned
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// 纯 AVFoundation 的扫码控制器。
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onError: ((String, Bool) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didConfigure = false
    /// 只上报一次，避免同一个二维码连续触发。
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        requestAccessAndConfigure()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 页面退出时务必停掉 session，否则相机会一直占用（发热、耗电）。
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func requestAccessAndConfigure() {
        guard !didConfigure else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            // 🚨 相机权限只在这里（用户主动点「Scan QR Code」进入扫码页）按需请求，
            // 不在 App 启动期、不在权限说明卡里请求（5.1.1(iv) Just-in-Time）。
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onError?(L("Camera access was denied. Enable it in Settings to scan."), true)
                    }
                }
            }
        default:
            // 已拒绝 / 受限：系统不会再弹框，只能去系统设置里打开 —— 给出明确出路。
            onError?(L("Camera access was denied. Enable it in Settings to scan."), true)
        }
    }

    private func configureSession() {
        guard !didConfigure else { return }
        didConfigure = true

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            // 模拟器没有相机设备，会走到这里。（非权限问题，不给「打开系统设置」）
            onError?(L("Camera is not available on this device."), false)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?(L("Camera is not available on this device."), false)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // 只认二维码；Mac 端渲染的是 QR。
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        // startRunning 是阻塞调用，必须放后台队列，否则会卡住主线程（表现为打开就卡死）。
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue, !value.isEmpty else { return }
        hasScanned = true
        if session.isRunning {
            session.stopRunning()
        }
        onScanned?(value)
    }
}
