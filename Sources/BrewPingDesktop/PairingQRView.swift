import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// 渲染一个 brewping://pair?... 配对链接的 QR 码图片。
///
/// CIQRCodeGenerator 生成的是单色位图（黑底白前景或白底黑前景），
/// 这里再做一步近邻采样放大 + 强制白底，避免菜单栏深色背景下变成黑块。
struct PairingQRView: View {
    let url: URL

    var body: some View {
        if let image = render(size: 220) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        } else {
            // 渲染失败的兜底：占位框，避免 UI 跳变。
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 180, height: 180)
                .overlay(
                    Image(systemName: "qrcode")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private func render(size pixel: CGFloat) -> NSImage? {
        guard let data = url.absoluteString.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"   // 15% 容错，URL 短 + 不易遮挡，足够
        guard let ciImage = filter.outputImage else { return nil }

        // 单像素的 CIImage 直接画出来只有 25x25 左右，必须放大。
        // 用最近邻采样保持锐利的方块边。
        let scale = pixel / max(ciImage.extent.width, 1)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: pixel, height: pixel))
    }
}
