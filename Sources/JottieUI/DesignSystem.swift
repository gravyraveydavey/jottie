import SwiftUI
import AppKit
import CoreText

/// Native equivalents of the prototype's semantic tokens and base-nova controls.
enum JottieStyle {
    static let accent = adaptive(0x7049C9, 0xBEA2F1)
    static let background = adaptive(0xFFFFFF, 0x171717)
    static let sidebar = adaptive(0xFAFAFA, 0x202020)
    static let foreground = adaptive(0x171717, 0xFAFAFA)
    static let muted = adaptive(0x838383, 0xACACAC)
    static let border = adaptive(0xE6E6E6, 0x383838)
    static let surface = adaptive(0xF5F5F5, 0x292929)
    static let selection = adaptive(0xF5F2FD, 0x30283E)
    static let navigationSelection = adaptive(0xEFE9FD, 0x3B2E50)
    static let selectedText = adaptive(0x514075, 0xE7DBFC)
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    private static let registerFonts: Void = {
        for name in ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "GeistMono-Regular"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()
    static func font(_ size: CGFloat = 14, _ weight: Font.Weight = .regular) -> Font {
        _ = registerFonts
        let name = weight == .semibold || weight == .bold ? "Geist-SemiBold" : weight == .medium ? "Geist-Medium" : "Geist-Regular"
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat = 11) -> Font { _ = registerFonts; return .custom("GeistMono-Regular", size: size) }
}

struct JottieButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, ghost, destructive }
    var kind: Kind = .ghost
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, compact: compact)
    }
    private struct StyledButton: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) var enabled
        @ViewState private var hovering = false
        var body: some View {
            configuration.label
                .font(JottieStyle.font(compact ? 12 : 14, .medium))
                .padding(.horizontal, compact ? 8 : 10).frame(minHeight: compact ? 28 : 32)
                .foregroundStyle(kind == .primary ? Color.white : kind == .destructive ? .red : JottieStyle.foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(kind == .outline ? JottieStyle.border : .clear, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
        private var background: Color {
            if kind == .primary { return JottieStyle.accent.opacity(hovering ? 0.87 : 1) }
            if kind == .destructive { return .red.opacity(hovering ? 0.15 : 0.08) }
            if hovering || configuration.isPressed { return JottieStyle.surface }
            return kind == .outline ? JottieStyle.background : .clear
        }
    }
}

struct JottieBadge: View {
    let text: String
    var outlined = false
    var body: some View {
        Text(text).font(JottieStyle.font(11, .medium)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(outlined ? JottieStyle.background : JottieStyle.surface, in: Capsule())
            .overlay { Capsule().stroke(outlined ? JottieStyle.border : .clear, lineWidth: 1) }
    }
}

struct JottieRule: View {
    var body: some View { Rectangle().fill(JottieStyle.border).frame(height: 1) }
}

struct JottieInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(JottieStyle.font())
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(JottieStyle.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(JottieStyle.border, lineWidth: 1) }
    }
}

struct JottieEmpty: View {
    let title: String
    let message: String
    var icon = "waveform"
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 25)).foregroundStyle(JottieStyle.accent)
                .frame(width: 48, height: 48).background(JottieStyle.selection, in: RoundedRectangle(cornerRadius: 12))
            Text(title).font(JottieStyle.font(18, .semibold))
            Text(message).font(JottieStyle.font(13)).foregroundStyle(JottieStyle.muted)
                .multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 340)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JottieSection<Content: View>: View {
    let title: String
    var icon: String? = nil
    var count: Int? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(JottieStyle.accent) }
                Text(title).font(JottieStyle.font(14, .semibold))
                if let count { JottieBadge(text: String(count)) }
            }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A one-point separator with a generous drag target. Keeping pane widths in
/// SwiftUI state avoids HSplitView redistributing its ideal widths after layout.
struct JottieDivider: View {
    @Binding var width: CGFloat
    let limits: ClosedRange<CGFloat>
    let defaultWidth: CGFloat
    let label: String
    @ViewState private var start: CGFloat?
    @ViewState private var hovering = false
    var body: some View {
        JottieStyle.border.frame(width: 1)
            .frame(width: 5).background(JottieStyle.background)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if start == nil { start = width }
                    width = min(limits.upperBound, max(limits.lowerBound, (start ?? width) + value.translation.width))
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { width = min(limits.upperBound, max(limits.lowerBound, defaultWidth)) }
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .focusable().focusEffectDisabled()
            .onMoveCommand { direction in
                if direction == .left { width = max(limits.lowerBound, width - 16) }
                if direction == .right { width = min(limits.upperBound, width + 16) }
            }
            .accessibilityLabel(label).accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { width = min(limits.upperBound, width + 16) }
                if direction == .decrement { width = max(limits.lowerBound, width - 16) }
            }
            .help("Drag to resize; double-click to reset")
    }
}

/// Native rendering of the supplied Lucide import paths (24×24 view box).
struct JottieImportIcon: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x:12,y:3)); path.addLine(to: CGPoint(x:12,y:15))
                path.move(to: CGPoint(x:8,y:11)); path.addLine(to: CGPoint(x:12,y:15)); path.addLine(to: CGPoint(x:16,y:11))
                path.move(to: CGPoint(x:8,y:5)); path.addLine(to: CGPoint(x:4,y:5))
                path.addQuadCurve(to: CGPoint(x:2,y:7), control: CGPoint(x:2,y:5))
                path.addLine(to: CGPoint(x:2,y:17)); path.addQuadCurve(to: CGPoint(x:4,y:19), control: CGPoint(x:2,y:19))
                path.addLine(to: CGPoint(x:20,y:19)); path.addQuadCurve(to: CGPoint(x:22,y:17), control: CGPoint(x:22,y:19))
                path.addLine(to: CGPoint(x:22,y:7)); path.addQuadCurve(to: CGPoint(x:20,y:5), control: CGPoint(x:22,y:5)); path.addLine(to: CGPoint(x:16,y:5))
            }.applying(CGAffineTransform(scaleX: geometry.size.width / 24, y: geometry.size.height / 24))
                .stroke(style: StrokeStyle(lineWidth: geometry.size.width / 12, lineCap: .round, lineJoin: .round))
        }.frame(width: 16, height: 16).accessibilityHidden(true)
    }
}
