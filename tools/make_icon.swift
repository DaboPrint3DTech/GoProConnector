// Generates Resources/AppIcon.icns (the app icon) by drawing it as vector graphics.
// Camera + WiFi waves, with the orange DaboPrint3D thumbs-up in a badge at the bottom right.
// Usage: swift tools/make_icon.swift Resources/AppIcon.icns [preview.png]
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func withShadow(blur: CGFloat, dy: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// DaboPrint3D logo colours
let orangeLight = rgb(0xFFA448)
let orange = rgb(0xF47F22)
let orangeDark = rgb(0xD95F12)
let ink = rgb(0x1E1E1E)
let teal = rgb(0x2AA8A2)

/// Cartoon thumbs-up (thick dark outline, orange gradient), in a local ~1000×1000 coordinate system.
func drawThumbsUp() {
    let ow: CGFloat = 30  // outline width

    // Cuff + palm + thumb: one shape with a single outer outline
    let cuff = rounded(150, 230, 200, 330, 55)
    let palm = rounded(270, 210, 370, 440, 140)
    let thumb = rounded(370, 520, 195, 410, 97)
    let body = NSBezierPath()
    body.append(cuff); body.append(palm); body.append(thumb)

    ink.setStroke()
    body.lineWidth = ow * 2
    body.lineJoinStyle = .round
    body.stroke()
    NSGradient(colors: [orangeLight, orange, orangeDark])!.draw(in: body, angle: -65)

    // Slightly darker cuff, with the dark rim of the opening
    orangeDark.withAlphaComponent(0.35).setFill()
    rounded(150, 230, 190, 330, 55).fill()
    ink.setFill()
    rounded(130, 214, 64, 362, 32).fill()
    ink.setStroke()
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: 340, y: 250))
    seam.curve(to: NSPoint(x: 340, y: 540), controlPoint1: NSPoint(x: 356, y: 340), controlPoint2: NSPoint(x: 356, y: 450))
    seam.lineWidth = ow * 0.5
    seam.lineCapStyle = .round
    seam.stroke()

    // Crease between thumb and index finger
    let crease = NSBezierPath()
    crease.move(to: NSPoint(x: 400, y: 480))
    crease.curve(to: NSPoint(x: 515, y: 560), controlPoint1: NSPoint(x: 450, y: 478), controlPoint2: NSPoint(x: 495, y: 510))
    crease.lineWidth = ow * 0.65
    crease.lineCapStyle = .round
    crease.stroke()

    // Four curled fingers, from the lowest to the highest (the index finger is on top)
    let fingers: [(CGFloat, CGFloat, CGFloat)] = [  // x, y, width
        (505, 212, 225), (515, 330, 250), (515, 448, 262), (500, 566, 272),
    ]
    for (x, y, w) in fingers {
        let f = rounded(x, y, w, 128, 64)
        NSGradient(colors: [orangeLight, orange, orangeDark])!.draw(in: f, angle: -80)
        ink.setStroke()
        f.lineWidth = ow
        f.stroke()
        rgb(0xFFFFFF, 0.35).setFill()  // highlight on the knuckles
        NSBezierPath(ovalIn: NSRect(x: x + w - 100, y: y + 74, width: 58, height: 24)).fill()
    }

    // Glossy highlight on the thumb
    rgb(0xFFFFFF, 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: 405, y: 750, width: 50, height: 130)).fill()
}

/// Draws the icon on a 1024×1024 canvas (origin at the bottom left).
func drawIcon() {
    // macOS-style "squircle" background with a soft shadow
    let tilePath = rounded(100, 100, 824, 824, 185)
    withShadow(blur: 24, dy: -10, alpha: 0.35) { rgb(0x0B3A8C).setFill(); tilePath.fill() }
    NSGradient(colors: [rgb(0x3A8DFF), rgb(0x1452C4), rgb(0x0B2F78)])!.draw(in: tilePath, angle: -90)

    // Camera body
    let bodyPath = rounded(196, 250, 420, 340, 86)
    withShadow(blur: 18, dy: -8, alpha: 0.30) { rgb(0xF4F6FA).setFill(); bodyPath.fill() }
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xDCE2EC)])!.draw(in: bodyPath, angle: -90)

    // Shutter button
    rgb(0xDCE2EC).setFill()
    rounded(466, 578, 88, 26, 10).fill()

    // Front display
    rgb(0x1B2433).setFill()
    rounded(234, 490, 104, 66, 15).fill()
    rgb(0x3A8DFF, 0.55).setFill()
    rounded(245, 501, 82, 44, 8).fill()

    // Lens
    let c = NSPoint(x: 452, y: 404)
    rgb(0x1B2433).setFill(); circle(c, 122).fill()
    rgb(0x3E4A5E).setFill(); circle(c, 96).fill()
    NSGradient(colors: [rgb(0x0E1420), rgb(0x24456F)])!.draw(in: circle(c, 74), angle: 60)
    rgb(0x5AA8FF, 0.9).setStroke()
    let ring = circle(c, 74); ring.lineWidth = 8; ring.stroke()
    rgb(0xFFFFFF, 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 41, y: c.y + 13, width: 28, height: 28)).fill()
    rgb(0xFFFFFF, 0.25).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x + 17, y: c.y - 37, width: 13, height: 13)).fill()

    // WiFi waves above the camera
    let w = NSPoint(x: 406, y: 652)
    rgb(0xFFFFFF).setStroke()
    for r: CGFloat in [62, 124, 186] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: w, radius: r, startAngle: 48, endAngle: 132)
        arc.lineWidth = 34
        arc.lineCapStyle = .round
        arc.stroke()
    }
    rgb(0xFFFFFF).setFill()
    circle(NSPoint(x: w.x, y: w.y + 14), 21).fill()

    // DaboPrint3D badge: white circle with a teal ring and the orange thumbs-up
    let b = NSPoint(x: 738, y: 288)
    withShadow(blur: 20, dy: -8, alpha: 0.40) { ink.setFill(); circle(b, 152).fill() }
    teal.setFill(); circle(b, 146).fill()
    ink.setFill(); circle(b, 125).fill()
    NSColor.white.setFill(); circle(b, 121).fill()

    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: b.x + 2, y: b.y + 12)
    ctx.rotate(by: -8 * .pi / 180)
    ctx.scaleBy(x: 0.26, y: 0.26)
    ctx.translateBy(x: -455, y: -568)
    drawThumbsUp()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    ctx.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {  // optional PNG preview (1024 px and 64 px)
    let preview = URL(fileURLWithPath: CommandLine.arguments[2])
    try! png(size: 1024).write(to: preview)
    try! png(size: 64).write(to: preview.deletingPathExtension().appendingPathExtension("64.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Created \(output)" : "iconutil failed")
