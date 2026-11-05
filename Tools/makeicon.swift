import AppKit
import CoreGraphics

// Generates a 1024x1024 app icon: a snowflake on a deep blue rounded tile.
// Run with: swiftc -O Tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }

let full = CGRect(x: 0, y: 0, width: size, height: size)

// Rounded tile
let tile = CGPath(roundedRect: full.insetBy(dx: 48, dy: 48),
                  cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()

let colors = [
    CGColor(red: 0.16, green: 0.22, blue: 0.40, alpha: 1.0),
    CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1.0)
]
let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

// Soft glow behind the flake
let glow = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0.75, green: 0.86, blue: 1.0, alpha: 0.30),
                               CGColor(red: 0.75, green: 0.86, blue: 1.0, alpha: 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: 512, y: 512), startRadius: 20,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 400,
                       options: [])

// Snowflake
let ice = CGColor(red: 0.93, green: 0.97, blue: 1.0, alpha: 1.0)
ctx.setStrokeColor(ice)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let center = CGPoint(x: 512, y: 512)
let armLength: CGFloat = 330

func line(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) {
    ctx.setLineWidth(w)
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
}

for arm in 0..<6 {
    let angle = CGFloat(arm) * .pi / 3
    let dir = CGPoint(x: cos(angle), y: sin(angle))
    let tip = CGPoint(x: center.x + dir.x * armLength,
                      y: center.y + dir.y * armLength)
    line(center, tip, 22)

    // Branches
    for (frac, len, width) in [(CGFloat(0.45), CGFloat(95), CGFloat(16)),
                               (CGFloat(0.72), CGFloat(70), CGFloat(13))] {
        let base = CGPoint(x: center.x + dir.x * armLength * frac,
                           y: center.y + dir.y * armLength * frac)
        for side in [CGFloat(1), CGFloat(-1)] {
            let a2 = angle + side * .pi / 4.2
            let d2 = CGPoint(x: cos(a2), y: sin(a2))
            line(base, CGPoint(x: base.x + d2.x * len, y: base.y + d2.y * len), width)
        }
    }
}

// Center boss
ctx.setFillColor(ice)
ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))

ctx.restoreGState()

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
