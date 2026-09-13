import SwiftUI

// ─── 拿铁主题（Watch 版）────────────────────────────────────────────────────────
//
// 与 iOS `LatteTheme` 的 `Color.bp*` **同名同值** —— 同一套 HSL token
// （源自 Windows 桌面端 `styles/app.css` 的 `:root`）：
//   --background hsl(40 44% 97%)  奶白画布      --card      hsl(42 50% 99%)  奶泡卡片
//   --foreground hsl(24 32% 22%)  深咖文本      --primary   hsl(24 45% 40%)  暖咖品牌
//   --secondary  hsl(36 38% 91%)  米色气泡      --muted     hsl(38 33% 92%)  弱化面
//   --border     hsl(33 26% 85%)                --success   hsl(96 28% 36%)  抹茶绿
//   --warning    hsl(33 75% 42%)  焦糖琥珀      --destructive hsl(10 55% 44%) 暖红陶土
//
// 🚨 两份定义各自属于一个 target（iOS / watchOS），**不要**把这份文件加进 iOS target，
//    否则与 `LatteTheme.swift` 重复声明。改配色必须两端同批。
//
// 手表默认是黑底白字（深色外观），要呈现奶白主题必须**显式**指定底色与前景色：
// 所有 `Text` 都不要依赖系统 primary 色，一律用 `bpForeground` / `bpMutedForeground`。

extension Color {
    /// 奶白画布（页面底色）
    static let bpBackground = Color(red: 251 / 255, green: 248 / 255, blue: 244 / 255)
    /// 奶泡卡片
    static let bpCard = Color(red: 254 / 255, green: 253 / 255, blue: 251 / 255)
    /// 深咖主文本
    static let bpForeground = Color(red: 74 / 255, green: 53 / 255, blue: 38 / 255)
    /// 暖咖品牌色
    static let bpPrimary = Color(red: 148 / 255, green: 93 / 255, blue: 56 / 255)
    /// 主色上的前景（奶白）
    static let bpPrimaryForeground = Color(red: 253 / 255, green: 252 / 255, blue: 250 / 255)
    /// 米色（用户气泡底色）
    static let bpSecondary = Color(red: 241 / 255, green: 234 / 255, blue: 223 / 255)
    /// 米色上的深咖文本
    static let bpSecondaryForeground = Color(red: 88 / 255, green: 62 / 255, blue: 45 / 255)
    /// 弱化面
    static let bpMuted = Color(red: 241 / 255, green: 236 / 255, blue: 228 / 255)
    /// 弱化文本（时间戳、说明）
    static let bpMutedForeground = Color(red: 135 / 255, green: 110 / 255, blue: 90 / 255)
    /// 浅棕悬停/选中面
    static let bpAccent = Color(red: 237 / 255, green: 226 / 255, blue: 212 / 255)
    /// 细边框
    static let bpBorder = Color(red: 227 / 255, green: 218 / 255, blue: 207 / 255)
    /// 抹茶绿（成功 / 在线）
    static let bpSuccess = Color(red: 87 / 255, green: 117 / 255, blue: 66 / 255)
    /// 焦糖琥珀（警告 / 进行中）
    static let bpWarning = Color(red: 187 / 255, green: 115 / 255, blue: 27 / 255)
    /// 暖红陶土（错误 / 离线）
    static let bpDestructive = Color(red: 174 / 255, green: 71 / 255, blue: 50 / 255)
}

// MARK: - 通用样式助手

extension View {
    /// 奶白底色铺满整块屏幕。
    /// watchOS 10 起 App 需要用 `containerBackground` 才能拿到全出血背景，
    /// 普通卡片/子视图则用 `.background(...)` 即可。
    @ViewBuilder
    func bpScreenBackground() -> some View {
        containerBackground(for: .navigation) {
            Color.bpBackground
        }
    }

    /// 奶泡卡片：圆角 + 1pt 描边，与 iOS / 桌面端的卡片观感一致。
    func bpCardStyle(cornerRadius: CGFloat = 10) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.bpBorder, lineWidth: 1)
        }
    }
}

// MARK: - 文案助手

/// 时间戳（对齐 iOS `bpTimeLabel`：今天只显示时间，其余「月-日 时:分」）。
func bpWatchTimeLabel(ms: Double) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let formatter = DateFormatter()
    // 固定 POSIX：24 小时制，不受系统区域设置影响
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
    return formatter.string(from: date)
}
