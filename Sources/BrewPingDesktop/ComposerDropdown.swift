import BrewPingCore
import SwiftUI

// ─── Composer 工具栏下拉（对齐 composer-dropdown.tsx）──────────────────────────
//
// 触发器 = 图标 + 单行截断文案 + chevron；弹层 = 向上/向下展开的圆角卡片，
// 条目两行排版（主文案 + 次要描述），hover 浅棕面、选中项右侧对勾。
// 仅样式层替换，onChange 语义与原 `<select>` 完全一致。

struct ComposerDropdown: View {
    var icon: String
    var title: String
    var value: String
    /// (value, label, description)
    var options: [(value: String, label: String, description: String?)]
    var onChange: (String) -> Void
    var maxTriggerWidth: CGFloat = 160
    /// 触发器文案的强调色（授权档位 askAll=warning / auto=success 用）。
    var tint: Color?

    @State private var open = false
    @State private var hovering = false

    private var current: (value: String, label: String, description: String?)? {
        options.first { $0.value == value }
    }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text(current?.label ?? "")
                    .font(LatteFont.xs)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.6)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(tint ?? (open || hovering ? Latte.foreground : Latte.mutedForeground))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: maxTriggerWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(open ? Latte.accent : (hovering ? Latte.accent : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options, id: \.value) { option in
                        item(option)
                    }
                }
                .padding(6)
            }
            .frame(minWidth: 176, maxWidth: 320)
            .frame(maxHeight: 360)
            .background(Latte.popover)
        }
    }

    private func item(_ option: (value: String, label: String, description: String?)) -> some View {
        let selected = option.value == value
        return Button {
            onChange(option.value)
            open = false
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(LatteFont.xs.weight(.medium))
                        .foregroundStyle(Latte.popoverForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let description = option.description {
                        Text(description)
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Latte.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Latte.accent.opacity(0.6) : .clear)
        )
        .help(option.description.map { "\(option.label) · \($0)" } ?? option.label)
    }
}
