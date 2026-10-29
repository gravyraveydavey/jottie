#!/usr/bin/env swift
// Jottie's workspace badge: SF Symbols waveform, medium weight, white on #7049C9.
// Generate the classic macOS icon and a transparent Icon Composer foreground.
import AppKit
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-jottie-icon: \(message)\n".utf8))
    exit(1)
}

private func squircle(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    for step in 0...720 {
        let angle = CGFloat(step) / 720 * 2 * .pi
        let c = cos(angle), s = sin(angle)
        let point = NSPoint(x: rect.midX + rect.width / 2 * copysign(pow(abs(c), 0.4), c),
                            y: rect.midY + rect.height / 2 * copysign(pow(abs(s), 0.4), s))
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

private func render(pixels: Int, foregroundOnly: Bool = false) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fail("cannot create bitmap") }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    let n = CGFloat(pixels)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: n, height: n).fill()
    let side = n * 0.824
    let plate = NSRect(x: (n - side) / 2, y: (n - side) / 2 + (foregroundOnly ? 0 : n * 0.012),
                       width: side, height: side)
    if !foregroundOnly {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = n * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -n * 0.012)
        shadow.set()
        NSColor(srgbRed: 112.0 / 255, green: 73.0 / 255, blue: 201.0 / 255, alpha: 1).setFill()
        squircle(in: plate).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // Match the sidebar's 22-point symbol on its 36-point badge. Rasterize
    // separately at every size to preserve the system symbol's small-size detail.
    let config = NSImage.SymbolConfiguration(pointSize: side * 22 / 36, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { fail("waveform symbol is unavailable") }
    let rect = NSRect(x: plate.midX - symbol.size.width / 2, y: plate.midY - symbol.size.height / 2,
                      width: symbol.size.width, height: symbol.size.height)
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    return bitmap
}

private func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fail("PNG encoding failed") }
    try data.write(to: url)
}

let args = CommandLine.arguments
let fm = FileManager.default
if args.count == 3, args[1] == "--adaptive-layer" {
    let output = URL(fileURLWithPath: args[2]).standardizedFileURL
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writePNG(render(pixels: 1024, foregroundOnly: true), to: output)
    print("wrote \(output.path)")
} else {
    guard args.count == 2 else { fail("usage: make-jottie-icon.swift <output.icns> | --adaptive-layer <output.png>") }
    let output = URL(fileURLWithPath: args[1]).standardizedFileURL
    let work = fm.temporaryDirectory.appendingPathComponent("jottie-icon-\(UUID().uuidString)")
    let iconset = work.appendingPathComponent("Jottie.iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                            (256, 1), (256, 2), (512, 1), (512, 2)] {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        try writePNG(render(pixels: points * scale), to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("iconutil failed") }
    print("wrote \(output.path)")
}
