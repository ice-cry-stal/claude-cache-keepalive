import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

let bg = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: S - 64, height: S - 64),
                      xRadius: 230, yRadius: 230)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.30, alpha: 1.0),
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)
])!
grad.draw(in: bg, angle: -70)

if let sym = NSImage(systemSymbolName: "bolt.heart.fill", accessibilityDescription: nil),
   let s = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)) {
    let sz = s.size
    let tinted = NSImage(size: sz)
    tinted.lockFocus()
    s.draw(in: NSRect(origin: .zero, size: sz))
    NSColor(calibratedRed: 0.98, green: 0.56, blue: 0.36, alpha: 1.0).set()
    NSRect(origin: .zero, size: sz).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (S - sz.width) / 2, y: (S - sz.height) / 2,
                           width: sz.width, height: sz.height))
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon ok")
