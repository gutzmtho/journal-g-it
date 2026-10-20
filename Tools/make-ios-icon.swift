// iPhone-Symbol aus dem Mac-Symbol: Inhalt des abgerundeten Quadrats randlos auf 1024 px, ohne Transparenz.
// Danach Transparenz entfernen (App Store verlangt ein Symbol ohne Alphakanal): siehe README.
// Aufruf: swift Tools/make-ios-icon.swift App/Assets.xcassets/AppIcon.appiconset/icon-mac-1024.png iOS/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png
import AppKit

let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let top = NSColor(srgbRed: 252/255, green: 252/255, blue: 255/255, alpha: 1)
let bottom = NSColor(srgbRed: 238/255, green: 238/255, blue: 241/255, alpha: 1)
NSGradient(starting: bottom, ending: top)!.draw(in: full, angle: 90)
// Mac-Symbol: Quadrat liegt bei 100…924 (von 1024). Etwas enger schneiden, damit Rundung und Schatten wegfallen.
let k = source.size.width / 1024  // Bildgröße in Punkten kann von 1024 abweichen
let inset: CGFloat = 104 * k
let crop = NSRect(x: inset, y: inset, width: source.size.width - 2 * inset, height: source.size.height - 2 * inset)
source.draw(in: full, from: crop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
