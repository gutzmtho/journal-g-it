// App-Symbol für Journal g-IT: grünes Buch mit dunklem Rücken, auf dem Deckel das „G“ mit rotem Tupfer aus dem Logo,
// auf hellgrauem Grund. Selbst gezeichnet (Stil wie ein Notizbuch, angelehnt an MacJournal, ohne dessen Bild).
// Aufruf: swift Tools/make-book-icon.swift App/Assets.xcassets/AppIcon.appiconset iOS/Assets.xcassets/AppIcon.appiconset
// Das „G“ mit dem roten Tupfer kommt aus dem Logo von Gutzmann IT (Tools/logo-g.png): Schwarz und Rot werden
// ausgeschnitten, der graue Hintergrund fällt weg.
// Schreibt die Mac-Größen (icon-mac-*.png, mit Rand und Schatten) und das iPhone-Symbol (icon-ios-1024.png,
// randlos, ohne Transparenz – so verlangt es der App Store).
import AppKit
import UniformTypeIdentifiers

let macFolder = URL(fileURLWithPath: CommandLine.arguments[1])
let iosFolder = URL(fileURLWithPath: CommandLine.arguments[2])

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Gleichbleibende Zufallszahlen, damit die Struktur des Einbands bei jedem Lauf gleich aussieht.
struct Noise {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

/// Feine Lederstruktur: viele kleine helle und dunkle Punkte.
func texture(_ rect: NSRect, scale s: CGFloat) {
    var noise = Noise()
    let count = Int(rect.width * rect.height / (s * s) / 60)
    for _ in 0..<count {
        let x = rect.minX + noise.next() * rect.width
        let y = rect.minY + noise.next() * rect.height
        let d = (1.5 + noise.next() * 2.5) * s
        let light = noise.next() > 0.5
        (light ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.07)).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
    }
}

/// Rechteck, nur rechts abgerundet (Buchdeckel).
func rightRounded(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX, y: r.minY))
    p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
    p.curve(to: NSPoint(x: r.maxX, y: r.minY + radius),
            controlPoint1: NSPoint(x: r.maxX - radius * 0.45, y: r.minY),
            controlPoint2: NSPoint(x: r.maxX, y: r.minY + radius * 0.45))
    p.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
    p.curve(to: NSPoint(x: r.maxX - radius, y: r.maxY),
            controlPoint1: NSPoint(x: r.maxX, y: r.maxY - radius * 0.45),
            controlPoint2: NSPoint(x: r.maxX - radius * 0.45, y: r.maxY))
    p.line(to: NSPoint(x: r.minX, y: r.maxY))
    p.close()
    return p
}

/// Logo-Ebenen aus Tools/logo-g.png: schwarzes „G“ und roter Tupfer, je mit Transparenz, auf das Logo zugeschnitten.
let logoLayers: (black: CGImage, red: CGImage) = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("logo-g.png")
    let source = NSBitmapImageRep(data: try! Data(contentsOf: url))!
    let w = source.pixelsWide, h = source.pixelsHigh
    var black = [UInt8](repeating: 0, count: w * h * 4)
    var red = [UInt8](repeating: 0, count: w * h * 4)
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            guard let c = source.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255
            let luma = 0.3 * r + 0.59 * g + 0.11 * b
            let i = (y * w + x) * 4
            // Rot: Rot deutlich über Grün und Blau.
            let redness = r - max(g, b)
            if redness > 22 {
                let a = UInt8(min(255, (redness - 22) * 7))
                red[i] = 0xA8; red[i + 1] = 0x26; red[i + 2] = 0x1F; red[i + 3] = a
            } else if luma < 70 {
                // Schwarz: dunkler als die graue Linie im Hintergrund; weicher Rand.
                black[i + 3] = UInt8(min(255, (70 - luma) * 6))
                black[i] = 0x16; black[i + 1] = 0x16; black[i + 2] = 0x16
            } else { continue }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Vormultipliziert speichern und auf den Inhalt zuschneiden.
    func image(_ pixels: [UInt8]) -> CGImage {
        var p = pixels
        for i in stride(from: 0, to: p.count, by: 4) {
            let a = Int(p[i + 3])
            for k in 0..<3 { p[i + k] = UInt8(Int(p[i + k]) * a / 255) }
        }
        let provider = CGDataProvider(data: Data(p) as CFData)!
        let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
    }
    return (image(black), image(red))
}()

func draw(size: Int, mac: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let s = CGFloat(size) / 1024
    let full = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    let background = NSGradient(starting: rgb(0xD9D9DD), ending: rgb(0xF4F4F6))!

    // Grund: Mac abgerundetes Quadrat mit Schatten, iPhone randlos.
    let content: NSRect
    if mac {
        content = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: content, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.24)
        shadow.shadowBlurRadius = 28 * s
        shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        background.draw(in: shape, angle: 90)
    } else {
        content = full
        background.draw(in: full, angle: 90)
    }
    let u = content.width / 824  // Maßstab innerhalb des Grundes

    // Buch (Maße wie ein Notizbuch à la MacJournal): schmal und hoch, Rücken ein knappes Drittel,
    // rechts stark abgerundet, darunter die Seiten über die ganze Breite.
    let bw = 440 * u, bh = 572 * u
    let pagesHeight = 20 * u, backHeight = 7 * u
    let book = NSRect(x: content.midX - bw / 2, y: content.midY - bh / 2 + (pagesHeight + backHeight) / 2, width: bw, height: bh)
    let radius = 62 * u
    let spineWidth = bw * 0.25  // etwas schmaler, damit das Logo-G groß Platz hat

    // Rückdeckel (dunkel, schmal unter den Seiten) mit Schatten unter dem ganzen Buch.
    let whole = NSRect(x: book.minX, y: book.minY - pagesHeight - backHeight, width: bw, height: bh + pagesHeight + backHeight)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    shadow.shadowBlurRadius = 16 * u
    shadow.shadowOffset = NSSize(width: 0, height: -6 * u)
    shadow.set()
    rgb(0x46703C).setFill()
    rightRounded(whole, radius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Seiten: weiß, mit feinen grauen Linien, rechts der Rundung folgend.
    let pages = NSRect(x: book.minX, y: book.minY - pagesHeight, width: bw - 4 * u, height: pagesHeight + radius)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: whole.minX, y: pages.minY, width: bw, height: pagesHeight + 1)).addClip()
    rgb(0xF7F7F2).setFill()
    rightRounded(pages, radius: radius * 0.9).fill()
    rgb(0xC4C6BE).setStroke()
    for i in 1...3 {
        let inset = CGFloat(i) * pagesHeight / 4
        let line = rightRounded(NSRect(x: pages.minX, y: pages.minY + inset, width: pages.width - inset * 0.6, height: pages.height),
                                radius: radius * 0.9 - inset * 0.6)
        line.lineWidth = max(1, 1.4 * u)
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Deckel: gedecktes Salbeigrün mit Verlauf und Struktur.
    let cover = rightRounded(book, radius: radius)
    NSGraphicsContext.saveGraphicsState()
    cover.addClip()
    NSGradient(starting: rgb(0x78A766), ending: rgb(0x89B776))!.draw(in: book, angle: 90)
    texture(book, scale: u)
    // Rücken: dunkler Streifen links, zur Mitte hin etwas heller.
    let spine = NSRect(x: book.minX, y: book.minY, width: spineWidth, height: bh)
    NSGradient(colors: [rgb(0x45693B), rgb(0x52794A), rgb(0x4A7042)])!.draw(in: spine, angle: 0)
    texture(spine, scale: u)
    // Kante zwischen Rücken und Deckel: weicher Schatten.
    NSGradient(starting: rgb(0x000000, 0.20), ending: rgb(0x000000, 0))!
        .draw(in: NSRect(x: spine.maxX, y: book.minY, width: 12 * u, height: bh), angle: 0)
    // Leichter Glanz oben am Deckel.
    NSGradient(starting: rgb(0xFFFFFF, 0), ending: rgb(0xFFFFFF, 0.10))!
        .draw(in: NSRect(x: book.minX, y: book.maxY - bh * 0.35, width: bw, height: bh * 0.35), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Logo-„G“ mit rotem Tupfer im oberen Teil des Deckels.
    let face = NSRect(x: spine.maxX, y: book.minY, width: bw - spineWidth, height: bh)
    let logo = logoLayers
    let aspect = CGFloat(logo.black.width) / CGFloat(logo.black.height)
    var logoHeight = face.height * 0.70
    if logoHeight * aspect > face.width * 0.96 { logoHeight = face.width * 0.96 / aspect }
    let logoRect = NSRect(x: face.midX - logoHeight * aspect / 2, y: face.maxY - bh * 0.07 - logoHeight,
                          width: logoHeight * aspect, height: logoHeight)
    ctx.interpolationQuality = .high
    ctx.draw(logo.black, in: logoRect)
    ctx.draw(logo.red, in: logoRect)

    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    write(draw(size: px, mac: true), to: macFolder.appendingPathComponent("icon-mac-\(px).png"))
}
write(draw(size: 1024, mac: false), to: iosFolder.appendingPathComponent("icon-ios-1024.png"))
print("fertig")
