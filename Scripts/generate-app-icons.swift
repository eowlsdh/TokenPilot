import AppKit
import Foundation

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let appIconDir = projectRoot.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let iconsetDir = projectRoot.appendingPathComponent(".build/TokenPilot.iconset", isDirectory: true)
let outputICNS = projectRoot.appendingPathComponent("Resources/TokenPilot.icns")

let specs: [(pixels: Int, filename: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func color(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255
    let green = CGFloat((hex >> 8) & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func drawTokenPilotIcon(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "TokenPilotIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap representation"])
    }

    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "TokenPilotIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    context.cgContext.setAllowsAntialiasing(true)

    let size = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.225
    let outer = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.03, dy: size * 0.03), xRadius: radius, yRadius: radius)
    outer.addClip()

    color(hex: 0x0a0a0b).setFill()
    rect.fill()

    if let gradient = NSGradient(colors: [
        color(hex: 0x111214),
        color(hex: 0x0b1220),
        color(hex: 0x0a0a0b)
    ]) {
        gradient.draw(in: outer, angle: -42)
    }

    let glowRect = rect.insetBy(dx: size * -0.20, dy: size * -0.15)
    let glow = NSBezierPath(ovalIn: NSRect(x: glowRect.midX - size * 0.18, y: glowRect.midY - size * 0.05, width: size * 0.72, height: size * 0.72))
    color(hex: 0x5b8cff, alpha: 0.20).setFill()
    glow.fill()

    let ringRect = rect.insetBy(dx: size * 0.19, dy: size * 0.19)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = max(size * 0.045, 1.2)
    color(hex: 0x263241, alpha: 0.95).setStroke()
    ring.stroke()

    let activeArc = NSBezierPath()
    activeArc.appendArc(
        withCenter: NSPoint(x: rect.midX, y: rect.midY),
        radius: ringRect.width / 2,
        startAngle: 218,
        endAngle: 35,
        clockwise: false
    )
    activeArc.lineWidth = max(size * 0.052, 1.5)
    activeArc.lineCapStyle = .round
    color(hex: 0x5b8cff, alpha: 1).setStroke()
    activeArc.stroke()

    let markerCount = pixels < 64 ? 3 : 5
    for index in 0..<markerCount {
        let angle = CGFloat(215 + index * (110 / max(markerCount - 1, 1))) * .pi / 180
        let outerRadius = ringRect.width / 2 + size * 0.02
        let innerRadius = outerRadius - size * 0.055
        let start = NSPoint(x: rect.midX + cos(angle) * innerRadius, y: rect.midY + sin(angle) * innerRadius)
        let end = NSPoint(x: rect.midX + cos(angle) * outerRadius, y: rect.midY + sin(angle) * outerRadius)
        let marker = NSBezierPath()
        marker.move(to: start)
        marker.line(to: end)
        marker.lineWidth = max(size * 0.012, 0.8)
        marker.lineCapStyle = .round
        color(hex: 0xe5edf5, alpha: 0.72).setStroke()
        marker.stroke()
    }

    let tokenWidth = size * 0.115
    let tokenGap = size * 0.035
    let baseY = rect.midY - size * 0.16
    let heights = [size * 0.20, size * 0.30, size * 0.43]
    let colors: [NSColor] = [color(hex: 0x30d158), color(hex: 0xf5a524), color(hex: 0x5b8cff)]
    let totalWidth = tokenWidth * 3 + tokenGap * 2
    for index in 0..<3 {
        let x = rect.midX - totalWidth / 2 + CGFloat(index) * (tokenWidth + tokenGap)
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: tokenWidth, height: heights[index]), xRadius: tokenWidth * 0.36, yRadius: tokenWidth * 0.36)
        colors[index].withAlphaComponent(index == 0 ? 0.72 : 0.90).setFill()
        bar.fill()
    }

    let underline = NSBezierPath()
    underline.move(to: NSPoint(x: rect.midX - size * 0.20, y: rect.midY - size * 0.24))
    underline.line(to: NSPoint(x: rect.midX + size * 0.20, y: rect.midY - size * 0.24))
    underline.lineWidth = max(size * 0.018, 1)
    underline.lineCapStyle = .round
    color(hex: 0xe5edf5, alpha: 0.48).setStroke()
    underline.stroke()

    let border = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: radius * 0.95, yRadius: radius * 0.95)
    border.lineWidth = max(size * 0.012, 1)
    color(hex: 0xe5edf5, alpha: 0.16).setStroke()
    border.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TokenPilotIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    return data
}

try FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: iconsetDir.path) {
    try FileManager.default.removeItem(at: iconsetDir)
}
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for spec in specs {
    let data = try drawTokenPilotIcon(pixels: spec.pixels)
    try data.write(to: appIconDir.appendingPathComponent(spec.filename), options: .atomic)
    try data.write(to: iconsetDir.appendingPathComponent(spec.filename), options: .atomic)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputICNS.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "TokenPilotIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print("Generated TokenPilot app icons and icns at \(appIconDir.path)")
