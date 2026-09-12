import AppKit
import SwiftUI

// ─── 拿铁主题令牌（macOS 版）────────────────────────────────────────────────────
//
// 令牌**逐条**照搬 Windows `src/styles/app.css` 的 `:root`（HSL 通道值），
// 保证两台机器上的桌面端看起来是同一个产品。
//
// 与 Windows 的差异只在「表达方式」：
//   · CSS `hsl(var(--x))` → Swift `Color.latte(h:s:l:)`（自实现 HSL→sRGB）；
//   · Tailwind 工具类（`bg-card`、`px-3`）→ 本文件里的具名常量 + SwiftUI 修饰符；
//   · `shadow-xs` / `shadow-panel` → `LatteShadow`（暖色投影，规范 §5.2）。

// MARK: - HSL → Color

public extension Color {
    /// 按 CSS `hsl(H S% L%)` 语义构造颜色（sRGB，与浏览器一致的取值）。
    static func latte(h: Double, s: Double, l: Double, opacity: Double = 1) -> Color {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let sat = min(max(s / 100, 0), 1)
        let light = min(max(l / 100, 0), 1)

        if sat == 0 {
            return Color(.sRGB, red: light, green: light, blue: light, opacity: opacity)
        }
        let q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
        let p = 2 * light - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return Color(
            .sRGB,
            red: channel(hue + 1.0 / 3),
            green: channel(hue),
            blue: channel(hue - 1.0 / 3),
            opacity: opacity
        )
    }
}

// MARK: - 设计令牌

/// 拿铁主题色板。命名与 `app.css` 的 CSS 变量一一对应。
public enum Latte {

    // 表面
    /// `--background` 奶白画布
    public static let background = Color.latte(h: 40, s: 44, l: 97)
    /// `--foreground` 深咖主文本
    public static let foreground = Color.latte(h: 24, s: 32, l: 22)
    /// `--card` 卡片：比画布更亮的奶泡
    public static let card = Color.latte(h: 42, s: 50, l: 99)
    public static let cardForeground = Color.latte(h: 24, s: 32, l: 22)
    /// `--popover`
    public static let popover = Color.latte(h: 42, s: 50, l: 99)
    public static let popoverForeground = Color.latte(h: 24, s: 32, l: 22)

    // 品牌：暖咖
    /// `--primary`
    public static let primary = Color.latte(h: 24, s: 45, l: 40)
    /// `--primary-foreground`
    public static let primaryForeground = Color.latte(h: 42, s: 55, l: 98)

    // 次级 / 弱化
    /// `--secondary` 米色
    public static let secondary = Color.latte(h: 36, s: 38, l: 91)
    public static let secondaryForeground = Color.latte(h: 24, s: 32, l: 26)
    /// `--muted`
    public static let muted = Color.latte(h: 38, s: 33, l: 92)
    public static let mutedForeground = Color.latte(h: 27, s: 20, l: 44)
    /// `--accent` 悬停面：浅棕
    public static let accent = Color.latte(h: 34, s: 42, l: 88)
    public static let accentForeground = Color.latte(h: 24, s: 32, l: 24)

    // 语义
    /// `--destructive` 暖红陶土
    public static let destructive = Color.latte(h: 10, s: 55, l: 44)
    public static let destructiveForeground = Color.latte(h: 42, s: 55, l: 98)
    /// `--success` 抹茶绿（低饱和）
    public static let success = Color.latte(h: 96, s: 28, l: 36)
    /// `--warning` 焦糖琥珀
    public static let warning = Color.latte(h: 33, s: 75, l: 42)

    // 边框 / 输入族
    /// `--border`
    public static let border = Color.latte(h: 33, s: 26, l: 85)
    /// `--input` 凹陷灰面
    public static let input = Color.latte(h: 36, s: 30, l: 88)
    /// `--input-field` 可编辑控件一律用它
    public static let inputField = Color.latte(h: 42, s: 55, l: 99)
    /// `--input-border`
    public static let inputBorder = Color.latte(h: 33, s: 24, l: 80)
    /// `--ring`
    public static let ring = Color.latte(h: 24, s: 45, l: 40)

    // 终端区（拿铁纸面：奶油底 + 咖啡字）
    /// `--terminal-bg`
    public static let terminalBg = Color.latte(h: 39, s: 38, l: 95)
    /// `--terminal-foreground`
    public static let terminalForeground = Color.latte(h: 24, s: 30, l: 26)

    // 代码块
    /// `--code`
    public static let code = Color.latte(h: 38, s: 36, l: 93)
    public static let codeForeground = Color.latte(h: 24, s: 30, l: 24)
    public static let codeBorder = Color.latte(h: 33, s: 24, l: 82)

    // 终端输出行（`app.css` 里直接写死的几个色）
    /// `.output-line.normal`
    public static let outputNormal = Color.latte(h: 24, s: 25, l: 32)
    /// `.output-line.system`
    public static let outputSystem = Color.latte(h: 27, s: 20, l: 46)
    /// `.output-line.system.source-ios` / `.source-watch` 焦糖色高亮
    public static let outputRemote = Color.latte(h: 28, s: 55, l: 40)
    /// `.output-line.system.user-input`
    public static let outputUserInput = Color.latte(h: 24, s: 35, l: 22)
}

// MARK: - 投影

/// 规范 §5.2「airy, not heavy」——暖色投影。
public enum LatteShadow {
    /// `--shadow-xs`
    public static let xs = ShadowSpec(color: Color.latte(h: 30, s: 20, l: 20, opacity: 0.08),
                                      radius: 2, x: 0, y: 1)
    /// `--shadow-panel`
    public static let panel = ShadowSpec(color: Color.latte(h: 30, s: 20, l: 20, opacity: 0.09),
                                         radius: 30, x: 0, y: 10)
    /// composer / 弹层用的轻量卡片投影（`0 8px 28px rgba(63,46,30,.14)` 的近似）
    public static let popup = ShadowSpec(color: Color.latte(h: 28, s: 36, l: 18, opacity: 0.14),
                                         radius: 28, x: 0, y: 8)

    public struct ShadowSpec {
        public var color: Color
        public var radius: CGFloat
        public var x: CGFloat
        public var y: CGFloat
    }
}

public extension View {
    /// 套用一条投影规格。
    func latteShadow(_ spec: LatteShadow.ShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: spec.x, y: spec.y)
    }
}

// MARK: - 布局与字体规格

/// 布局规格令牌（`app.css` 的「布局规格令牌」段 + 正文基准）。
public enum LatteMetrics {
    /// `--control-h` 控件标准高 36pt
    public static let controlHeight: CGFloat = 36
    /// `--z-composer` 等 z 阶梯在 SwiftUI 里由视图层次决定，此处仅保留语义常量备查。
    public static let sidebarWidth: CGFloat = 208          // w-52 = 13rem = 208pt
    public static let titleBarHeight: CGFloat = 28          // h-7
    public static let headerHeight: CGFloat = 36            // h-9
    /// `CONVERSATION_CONTENT_WIDTH_CLASS`：max-w-[46rem] = 736pt
    public static let conversationContentWidth: CGFloat = 736
    /// `px-3 sm:px-4`：窄窗 12pt、宽窗 16pt
    public static let conversationGutterCompact: CGFloat = 12
    public static let conversationGutterRegular: CGFloat = 16
    /// 会话内容主列的可用宽度（宽度不足时退让，等价于 max-w 的行为）
    public static func conversationWidth(available: CGFloat) -> CGFloat {
        let gutter = available < 640 ? conversationGutterCompact : conversationGutterRegular
        return max(0, min(conversationContentWidth, available) - gutter * 2)
    }
}

/// 字体栈。Windows 用 `"Inter", system-ui, -apple-system, "Segoe UI", …`；
/// macOS 上 `system-ui` 就是 SF Pro —— 直接用系统字体即可拿到最地道的字面。
public enum LatteFont {
    /// 正文基准 14pt / 1.45（规格 §3.2）
    public static let base = Font.system(size: 14)
    public static let baseLineSpacing: CGFloat = 14 * 0.45
    /// 终端 / composer 输入用的等宽栈
    public static let mono = Font.system(size: 12, design: .monospaced)
    public static let mono11 = Font.system(size: 11, design: .monospaced)
    public static let monoXS = Font.system(size: 10, design: .monospaced)

    /// Tailwind `text-xs` = 12pt
    public static let xs = Font.system(size: 12)
    /// `text-sm` = 14pt
    public static let sm = Font.system(size: 14)
    /// `text-[10px]` / `text-[9px]` / `text-[11px]`
    public static let font10 = Font.system(size: 10)
    public static let font9 = Font.system(size: 9)
    public static let font11 = Font.system(size: 11)
    /// `text-xl`（配对码）
    public static let xl = Font.system(size: 20, weight: .semibold, design: .monospaced)
    /// landing 问候语 `text-4xl`
    public static let landing = Font.system(size: 36, weight: .semibold)
}
