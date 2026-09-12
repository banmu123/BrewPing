import SwiftUI

// ─── BrewPing 拿铁主题（与 Windows 桌面端 `styles/app.css` 的 HSL token 一一对应）──
//
// 换算自桌面端：
//   --background hsl(40 44% 97%)  奶白画布      --card      hsl(42 50% 99%)  奶泡卡片
//   --foreground hsl(24 32% 22%)  深咖文本      --primary   hsl(24 45% 40%)  暖咖品牌
//   --secondary  hsl(36 38% 91%)  米色气泡      --accent    hsl(34 42% 88%)  浅棕悬停面
//   --border     hsl(33 26% 85%)                --success   hsl(96 28% 36%)  抹茶绿
//   --warning    hsl(33 75% 42%)  焦糖琥珀      --destructive hsl(10 55% 44%) 暖红陶土
//
// 用法：视图里一律使用 `Color.bp*`，不要再写 `.blue` / `.green` 等系统色，
// 否则会与桌面端配色割裂。Watch 端有自己的配色（见 Watch/ContentView.swift），不要混用。

extension Color {
    /// 奶白画布（页面底色）
    static let bpBackground = Color(red: 251 / 255, green: 248 / 255, blue: 244 / 255)
    /// 奶泡卡片（比画布更亮一档，用于卡片/列表行）
    static let bpCard = Color(red: 254 / 255, green: 253 / 255, blue: 251 / 255)
    /// 深咖主文本
    static let bpForeground = Color(red: 74 / 255, green: 53 / 255, blue: 38 / 255)
    /// 暖咖品牌色（按钮/强调）
    static let bpPrimary = Color(red: 148 / 255, green: 93 / 255, blue: 56 / 255)
    /// 主色上的前景（奶白）
    static let bpPrimaryForeground = Color(red: 253 / 255, green: 252 / 255, blue: 250 / 255)
    /// 米色（用户气泡底色）
    static let bpSecondary = Color(red: 241 / 255, green: 234 / 255, blue: 223 / 255)
    /// 米色上的深咖文本
    static let bpSecondaryForeground = Color(red: 88 / 255, green: 62 / 255, blue: 45 / 255)
    /// 弱化面（禁用/次级底）
    static let bpMuted = Color(red: 241 / 255, green: 236 / 255, blue: 228 / 255)
    /// 弱化文本（时间戳、说明）
    static let bpMutedForeground = Color(red: 135 / 255, green: 110 / 255, blue: 90 / 255)
    /// 浅棕悬停面（选中行、chip 底）
    static let bpAccent = Color(red: 237 / 255, green: 226 / 255, blue: 212 / 255)
    /// 细边框
    static let bpBorder = Color(red: 227 / 255, green: 218 / 255, blue: 207 / 255)
    /// 输入控件边框
    static let bpInputBorder = Color(red: 216 / 255, green: 205 / 255, blue: 192 / 255)
    /// 抹茶绿（成功，低饱和）
    static let bpSuccess = Color(red: 87 / 255, green: 117 / 255, blue: 66 / 255)
    /// 焦糖琥珀（警告/进行中）
    static let bpWarning = Color(red: 187 / 255, green: 115 / 255, blue: 27 / 255)
    /// 暖红陶土（错误）
    static let bpDestructive = Color(red: 174 / 255, green: 71 / 255, blue: 50 / 255)
}

// ─── 通用样式助手 ─────────────────────────────────────────────────────────────

extension View {
    /// 拿铁底色铺满（配合 `List`/`Form` 的 `.scrollContentBackground(.hidden)` 使用）。
    func bpScreenBackground() -> some View {
        background(Color.bpBackground)
    }
}

/// 目录路径末段（`D:\study\workFlow` → `workFlow`），与桌面端 `pathLabel` 同规则。
func bpPathLabel(_ path: String) -> String {
    var trimmed = path
    while trimmed.hasSuffix("\\") || trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    if let idx = trimmed.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
        return String(trimmed[trimmed.index(after: idx)...])
    }
    return trimmed
}

/// 时间戳文案（对齐桌面端：今天只显示时间，其余显示「月-日 时:分」）。
func bpTimeLabel(ms: Double) -> String {
    let date = Date(timeIntervalSince1970: ms / 1000)
    let fmt = DateFormatter()
    // 固定 POSIX：24 小时制与桌面端一致，不受系统区域（12 小时制）影响
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
    return fmt.string(from: date)
}
