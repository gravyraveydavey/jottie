import AppKit

/// Jottie's soundwave mark, matching the workspace and application icon.
/// Shared by the menu bar, status window and About window.
enum JottieIcon {

    /// The soundwave at `size`. With a colour it is painted in that colour and
    /// marked non-template; without one it is a template image the system
    /// renders to match its surroundings.
    ///
    /// Painting rather than tinting is deliberate: `contentTintColor` doesn't
    /// reliably override template rendering, and over a dark wallpaper the
    /// "red" recording icon came out near-black on near-black — invisible in
    /// the one state that must never be (upstream issue #15).
    static func image(size: CGFloat, color: NSColor?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        guard let source = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Jottie")?
            .withSymbolConfiguration(configuration) else { return nil }
        source.isTemplate = false
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let scale = min(size / source.size.width, size / source.size.height)
        let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let symbolRect = NSRect(x: (size - fitted.width) / 2, y: (size - fitted.height) / 2,
                                width: fitted.width, height: fitted.height)
        let painted = NSImage(size: rect.size)
        painted.lockFocus()
        source.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
        (color ?? .black).set()
        rect.fill(using: .sourceAtop)
        painted.unlockFocus()
        painted.isTemplate = color == nil
        painted.accessibilityDescription = "Jottie"
        return painted
    }

    /// Colour for a recording state, or nil for idle (template rendering).
    static func color(recording: Bool, paused: Bool) -> NSColor? {
        if paused { return .systemOrange }
        if recording { return .systemRed }
        return nil
    }
}
