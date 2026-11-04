// Renders the app icon: a white sparkle on a blue-violet gradient (or the "bubbles" variant).
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns [minimal|bubbles]
import AppKit

let palette: [(Double, Double, Double)] = [
  (1.00, 0.42, 0.42), (1.00, 0.72, 0.25), (0.62, 0.88, 0.33), (0.20, 0.85, 0.75),
  (0.30, 0.70, 1.00), (0.55, 0.50, 1.00), (0.80, 0.45, 1.00), (1.00, 0.45, 0.75),
]

func color(_ rgb: (Double, Double, Double), _ alpha: Double = 1) -> NSColor {
  NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
}

let style = CommandLine.arguments.dropFirst(2).first ?? "minimal"

func sparkle(center: NSPoint, long: Double, short: Double) -> NSBezierPath {
  // Four-point star with concave sides.
  let path = NSBezierPath()
  for step in 0..<4 {
    let theta = Double(step) * .pi / 2 + .pi / 2
    let tip = NSPoint(x: center.x + long * cos(theta), y: center.y + long * sin(theta))
    let next = Double(step + 1) * .pi / 2 + .pi / 2
    let nextTip = NSPoint(x: center.x + long * cos(next), y: center.y + long * sin(next))
    if step == 0 { path.move(to: tip) }
    let mid = theta + .pi / 4
    let waist = NSPoint(x: center.x + short * cos(mid), y: center.y + short * sin(mid))
    path.curve(to: nextTip, controlPoint1: waist, controlPoint2: waist)
  }
  path.close()
  return path
}

func drawBubbles(in clip: NSBezierPath, scale s: Double) {
  NSGraphicsContext.saveGraphicsState()
  clip.addClip()
  // (x, y, radius, palette index): overlapping glossy bubbles.
  let bubbles: [(Double, Double, Double, Int)] = [
    (330, 640, 210, 4), (640, 700, 170, 6), (700, 400, 230, 0), (360, 330, 170, 3),
    (520, 520, 120, 1), (820, 640, 90, 7), (240, 470, 80, 2), (560, 250, 85, 5),
    (470, 790, 70, 1), (800, 260, 60, 3),
  ]
  for (x, y, r, index) in bubbles {
    let rect = NSRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)
    let bubble = NSBezierPath(ovalIn: rect)
    let base = palette[index]
    NSGradient(colors: [
      color((min(1, base.0 + 0.25), min(1, base.1 + 0.25), min(1, base.2 + 0.25)), 0.95),
      color(base, 0.80), color((base.0 * 0.55, base.1 * 0.55, base.2 * 0.6), 0.85),
    ])!.draw(in: bubble, relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
    NSColor.white.withAlphaComponent(0.35).setStroke()
    bubble.lineWidth = 3 * s
    bubble.stroke()
    let shine = NSBezierPath(
      ovalIn: NSRect(x: (x - r * 0.55) * s, y: (y + r * 0.25) * s, width: r * 0.5 * s, height: r * 0.32 * s))
    NSColor.white.withAlphaComponent(0.55).setFill()
    shine.fill()
  }
  NSColor.white.setFill()
  sparkle(center: NSPoint(x: 760 * s, y: 800 * s), long: 70 * s, short: 16 * s).fill()
  sparkle(center: NSPoint(x: 230 * s, y: 250 * s), long: 46 * s, short: 11 * s).fill()
  NSGraphicsContext.restoreGraphicsState()
}

func render(size: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = Double(size) / 1024
  let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
  let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
  shadow.shadowBlurRadius = 24 * s
  shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
  NSGraphicsContext.saveGraphicsState()
  shadow.set()
  color((0.05, 0.12, 0.22)).setFill()
  squircle.fill()
  NSGraphicsContext.restoreGraphicsState()

  if style == "bubbles" {
    NSGradient(colors: [color((0.10, 0.20, 0.42)), color((0.03, 0.06, 0.15))])!
      .draw(in: squircle, angle: -90)
  }

  let center = NSPoint(x: 512 * s, y: 512 * s)
  if style == "bubbles" {
    drawBubbles(in: squircle, scale: s)
  } else {
    NSGradient(colors: [color((0.30, 0.62, 1.00)), color((0.60, 0.36, 1.00)), color((0.93, 0.40, 0.78))])!
      .draw(in: squircle, angle: -60)
    let sheen = NSBezierPath(ovalIn: NSRect(x: 40 * s, y: 560 * s, width: 944 * s, height: 520 * s))
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
      .draw(in: sheen, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.65)
    glow.shadowBlurRadius = 40 * s
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    NSColor.white.setFill()
    sparkle(center: NSPoint(x: 490 * s, y: 490 * s), long: 250 * s, short: 54 * s).fill()
    sparkle(center: NSPoint(x: 712 * s, y: 712 * s), long: 92 * s, short: 22 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    _ = center
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent(
  "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    let data = render(size: base * scale).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent(name))
  }
}
try FileManager.default.createDirectory(
  at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(size: 1024).representation(using: .png, properties: [:])!
  .write(to: output.deletingPathExtension().appendingPathExtension("png"))
print("Wrote \(output.path)")
