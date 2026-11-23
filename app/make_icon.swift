// Renders the AirGlance app icon as a 1024 px PNG:
// the air quality monitor (white body, perforated grille, green status LED)
// on a mint squircle with soft air-flow lines.
// Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let k = size / 120   // design grid is 120 x 120 (y grows downwards)

func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * k, y: y * k, width: w * k, height: h * k) }
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext

    // background squircle (macOS icon grid: ~10% margin)
    let bg = NSBezierPath(roundedRect: r(10, 10, 100, 100), xRadius: 22.5 * k, yRadius: 22.5 * k)
    NSGradient(colors: [rgb(0xEAF8F2), rgb(0xCDEFE2)])!.draw(in: bg, angle: 90)

    // air-flow lines behind the device
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    for (y, alpha) in [(33.0, 1.0), (97.0, 0.85)] as [(CGFloat, CGFloat)] {
        let w = NSBezierPath()
        w.move(to: p(4, y))
        w.curve(to: p(40, y), controlPoint1: p(16, y - 8), controlPoint2: p(28, y + 8))
        w.curve(to: p(76, y), controlPoint1: p(52, y - 8), controlPoint2: p(64, y + 8))
        w.curve(to: p(116, y), controlPoint1: p(88, y - 8), controlPoint2: p(100, y + 8))
        w.lineWidth = 3.2 * k
        w.lineCapStyle = .round
        rgb(0x8ED9BC, alpha).setStroke()
        w.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // device body with soft shadow
    let body = NSBezierPath(roundedRect: r(24, 37, 72, 52), xRadius: 15 * k, yRadius: 15 * k)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 2.2 * k), blur: 7 * k, color: rgb(0x0F6E56, 0.28).cgColor)
    NSColor.white.setFill()
    body.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor.white, rgb(0xF3F2EE)])!.draw(in: body, angle: 90)
    rgb(0xC9C7BE).setStroke()
    body.lineWidth = 1.2 * k
    body.stroke()

    // lower housing seam
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    let seam = NSBezierPath()
    seam.move(to: p(24, 76.5)); seam.line(to: p(96, 76.5))
    seam.lineWidth = 1.1 * k
    rgb(0xDAD8D0).setStroke()
    seam.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // perforated grille
    let grille = NSBezierPath(roundedRect: r(36, 53, 48, 15), xRadius: 7.5 * k, yRadius: 7.5 * k)
    NSGradient(colors: [rgb(0x77766F), rgb(0x9A9990)])!.draw(in: grille, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    grille.addClip()
    rgb(0x3A3A37).setFill()
    for row in 0..<3 {
        let y = 56.5 + CGFloat(row) * 4
        let offset: CGFloat = row % 2 == 0 ? 0 : 2
        var x: CGFloat = 38 + offset
        while x < 83 {
            NSBezierPath(ovalIn: r(x - 1.05, y - 1.05, 2.1, 2.1)).fill()
            x += 4
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // status LED (glowing green)
    let led = NSBezierPath(roundedRect: r(57, 42.5, 6, 7.5), xRadius: 3 * k, yRadius: 3 * k)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 6 * k, color: rgb(0x1D9E75, 0.9).cgColor)
    rgb(0x1DB37F).setFill()
    led.fill()
    ctx.restoreGState()
    return true
}

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
