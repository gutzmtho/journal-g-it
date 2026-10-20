// App-Symbol für Journal g-IT – gleicher Stil wie Buttons g-IT (ButtonsIT/Tools/make-icons.py):
// „Journal" rot, „g-IT" grün, Menlo Bold, heller Verlauf, abgerundetes Quadrat mit Schatten.
// Aufruf: swift Tools/make-icons.swift <Zielordner AppIcon.appiconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let red = NSColor(srgbRed: 230/255, green: 57/255, blue: 46/255, alpha: 1)
let green = NSColor(srgbRed: 62/255, green: 122/255, blue: 48/255, alpha: 1)
let fontName = "Menlo-Bold"

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    // Mac: abgerundetes Quadrat 824 px mit Rand, Radius 185, leichter Schatten.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.24)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Sanfter Verlauf weiß → hellgrau (oben hell).
    let top = NSColor(srgbRed: 252/255, green: 252/255, blue: 255/255, alpha: 1)
    let bottom = NSColor(srgbRed: 238/255, green: 238/255, blue: 241/255, alpha: 1)
    NSGradient(starting: bottom, ending: top)!.draw(in: shape, angle: 90)

    // Schrift so groß, dass „Journal" ~80 % der Breite füllt.
    var fs: CGFloat = 10
    while (("Journal" as NSString).size(withAttributes: [.font: NSFont(name: fontName, size: fs + 1)!]).width) < rect.width * 0.80 {
        fs += 1
    }
    let font = NSFont(name: fontName, size: fs)!
    let lineHeight = (font.ascender - font.descender) * 1.05
    var y = rect.midY + lineHeight - font.ascender * 0.15
    for (word, color) in [("Journal", red), ("g-IT", green)] {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let w = (word as NSString).size(withAttributes: attrs).width
        y -= lineHeight
        (word as NSString).draw(at: NSPoint(x: rect.midX - w / 2, y: y - font.descender), withAttributes: attrs)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = point * scale
    let name = "icon-mac-\(px).png"
    if !FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path) {
        try drawIcon(size: px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(point)x\(point)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("fertig: \(out.path)")
