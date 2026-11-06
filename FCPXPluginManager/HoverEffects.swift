import SwiftUI
import AppKit

/// 统一点击反馈：鼠标移上去底色轻微变化 + 手型指针，约 0.12 秒过渡。
/// 颜色用 `Color.primary`，会自动跟随浅色 / 深色模式。
struct HoverTintModifier: ViewModifier {
    var cornerRadius: CGFloat = 5
    /// 危险操作（删除类）悬停转警示红
    var danger: Bool = false
    /// 调用方明确知道不可用时传 false；系统 .disabled 也会自动生效
    var isEnabled: Bool = true

    @Environment(\.isEnabled) private var environmentEnabled
    @State private var hovering = false

    private var active: Bool { isEnabled && environmentEnabled }

    private var fillColor: Color {
        guard hovering, active else { return .clear }
        return danger ? Color.red.opacity(0.18) : Color.primary.opacity(0.09)
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { inside in
                guard active else {
                    if hovering { hovering = false }
                    return
                }
                if hovering != inside {
                    hovering = inside
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
    }
}

/// 已经有实心底色的按钮（橙色「一键全部禁用」、绿色「恢复」等）：
/// 悬停时整体提亮，危险按钮叠加一层红。
struct HoverBrightenModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var danger: Bool = false
    var isEnabled: Bool = true

    @Environment(\.isEnabled) private var environmentEnabled
    @State private var hovering = false

    private var active: Bool { isEnabled && environmentEnabled }

    func body(content: Content) -> some View {
        content
            .overlay {
                if hovering && active {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(danger ? Color.red.opacity(0.20) : Color.white.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { inside in
                guard active else {
                    if hovering { hovering = false }
                    return
                }
                if hovering != inside {
                    hovering = inside
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
    }
}

extension View {
    /// 透明 / 文字型控件的悬停底色。危险操作用 danger: true。
    func hoverTint(cornerRadius: CGFloat = 5, danger: Bool = false, isEnabled: Bool = true) -> some View {
        modifier(HoverTintModifier(cornerRadius: cornerRadius, danger: danger, isEnabled: isEnabled))
    }

    /// 实心按钮的悬停提亮。危险操作用 danger: true。
    func hoverBrighten(cornerRadius: CGFloat = 8, danger: Bool = false, isEnabled: Bool = true) -> some View {
        modifier(HoverBrightenModifier(cornerRadius: cornerRadius, danger: danger, isEnabled: isEnabled))
    }
}
