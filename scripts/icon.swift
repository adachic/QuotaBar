import AppKit

let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 36, y: 36, width: 952, height: 952)
let background = NSBezierPath(roundedRect: rect, xRadius: 214, yRadius: 214)
NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.21, blue: 0.25, alpha: 1),
           ending: NSColor(calibratedRed: 0.055, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: background, angle: -70)
func battery(y: CGFloat, color: NSColor, fraction: CGFloat) {
    NSColor.white.withAlphaComponent(0.42).setStroke()
    let outline = NSBezierPath(roundedRect: NSRect(x: 222, y: y, width: 534, height: 180), xRadius: 42, yRadius: 42)
    outline.lineWidth = 13; outline.stroke()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 246, y: y + 24, width: 486 * fraction, height: 132), xRadius: 23, yRadius: 23).fill()
    NSColor.white.withAlphaComponent(0.53).setFill()
    NSBezierPath(roundedRect: NSRect(x: 775, y: y + 60, width: 24, height: 60), xRadius: 10, yRadius: 10).fill()
}
battery(y: 546, color: NSColor(calibratedRed: 0.34, green: 0.83, blue: 0.69, alpha: 1), fraction: 0.82)
battery(y: 291, color: NSColor(calibratedRed: 0.90, green: 0.65, blue: 0.49, alpha: 1), fraction: 0.62)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
