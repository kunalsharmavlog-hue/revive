// Draws the Revive app icon (1024×1024 PNG): a drive inside a "restore" arrow.
// Usage: swift make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS-style rounded square with a deep-blue to sky-blue gradient.
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(srgbRed: 0.10, green: 0.20, blue: 0.55, alpha: 1).setFill()
tilePath.fill()
ctx.restoreGState()
NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.65, blue: 0.91, alpha: 1),
                    NSColor(srgbRed: 0.12, green: 0.23, blue: 0.62, alpha: 1)])!
    .draw(in: tilePath, angle: -90)

// Soft highlight across the top half.
ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
ctx.restoreGState()

let c = NSPoint(x: size / 2, y: size / 2)

// Counter-clockwise "restore" arrow around the drive, open at the upper left.
let radius: CGFloat = 255, lineWidth: CGFloat = 64
let start: CGFloat = 150, end: CGFloat = 470           // degrees, counter-clockwise
let arc = NSBezierPath()
arc.appendArc(withCenter: c, radius: radius, startAngle: start, endAngle: end, clockwise: false)
arc.lineWidth = lineWidth
arc.lineCapStyle = .round
NSColor.white.setStroke()
arc.stroke()

// Arrowhead at the end of the arc, pointing along the counter-clockwise direction.
let t = end * .pi / 180
let tip = NSPoint(x: c.x + radius * cos(t), y: c.y + radius * sin(t))
let dir = NSPoint(x: -sin(t), y: cos(t))               // tangent (counter-clockwise)
let nrm = NSPoint(x: cos(t), y: sin(t))                // outward normal
let head: CGFloat = 92
let p1 = NSPoint(x: tip.x + dir.x * head * 0.9, y: tip.y + dir.y * head * 0.9)
let p2 = NSPoint(x: tip.x + nrm.x * head * 0.85 - dir.x * 10, y: tip.y + nrm.y * head * 0.85 - dir.y * 10)
let p3 = NSPoint(x: tip.x - nrm.x * head * 0.85 - dir.x * 10, y: tip.y - nrm.y * head * 0.85 - dir.y * 10)
let arrow = NSBezierPath()
arrow.move(to: p1); arrow.line(to: p2); arrow.line(to: p3); arrow.close()
arrow.lineJoinStyle = .round
arrow.lineWidth = 14
NSColor.white.setFill(); NSColor.white.setStroke()
arrow.fill(); arrow.stroke()

// The drive: a white rounded slab with a status light and vent lines.
let drive = NSRect(x: c.x - 165, y: c.y - 95, width: 330, height: 190)
ctx.saveGState()
let ds = NSShadow()
ds.shadowColor = NSColor.black.withAlphaComponent(0.25)
ds.shadowBlurRadius = 18
ds.shadowOffset = NSSize(width: 0, height: -8)
ds.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: drive, xRadius: 38, yRadius: 38).fill()
ctx.restoreGState()
NSColor(srgbRed: 0.13, green: 0.77, blue: 0.37, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: drive.maxX - 78, y: drive.midY - 20, width: 40, height: 40)).fill()
NSColor(srgbRed: 0.55, green: 0.70, blue: 0.90, alpha: 1).setFill()
for i in 0..<3 {
    let y = drive.midY + 34 - CGFloat(i) * 34
    NSBezierPath(roundedRect: NSRect(x: drive.minX + 42, y: y - 8, width: 150, height: 16), xRadius: 8, yRadius: 8).fill()
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
