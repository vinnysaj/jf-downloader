// Frames the raw captures for the App Store: each on the app icon's gradient with a caption,
// at the exact size of its App Store Connect slot, and draws the product page header and search
// results artwork from the showcase posters. Everything is written without alpha.
// Usage: swift Compose.swift <raw folder> <output folder> <media folder> [sets...]
import AppKit

let arguments = CommandLine.arguments.dropFirst().map(\.self)
let rawFolder = URL(fileURLWithPath: arguments[0])
let outputFolder = URL(fileURLWithPath: arguments[1])
let mediaFolder = URL(fileURLWithPath: arguments[2])
let sets = Set(arguments.dropFirst(3))
let fileManager = FileManager.default

// MARK: Slots and captions

struct Slot {
    /// The folder under Raw the captures come from.
    let raw: String
    /// The folder under the output, named for the App Store Connect slot.
    let folder: String
    /// What to put in front of each file name, when several devices share a slot.
    var prefix = ""
    /// Wider than tall.
    var landscape = false
    /// The screen's corner radius as a fraction of its width; zero for a window with its own.
    let cornerRadius: CGFloat
    let set: String

    /// The pixel size the slot takes for a capture of `size`.
    func canvas(for size: CGSize) -> CGSize {
        switch folder {
        case "iPhone 6.9-inch": CGSize(width: 1320, height: 2868)
        case "iPhone 6.3-inch": CGSize(width: 1206, height: 2622)
        case "iPad 13-inch": CGSize(width: 2752, height: 2064)
        case "Apple TV": CGSize(width: 3840, height: 2160)
        case "Mac": CGSize(width: 2880, height: 1800)
        // iPhone Duo takes both displays, upright or sideways: 1398×2034 outer, 2007×2853 inner.
        default:
            if prefix == "outer" { size.width > size.height ? CGSize(width: 2034, height: 1398) : CGSize(width: 1398, height: 2034) }
            else { size.width > size.height ? CGSize(width: 2853, height: 2007) : CGSize(width: 2007, height: 2853) }
        }
    }
}

let slots = [
    Slot(raw: "iPhone 6.9-inch", folder: "iPhone 6.9-inch", cornerRadius: 0.14, set: "iphone"),
    Slot(raw: "iPhone 6.3-inch", folder: "iPhone 6.3-inch", cornerRadius: 0.14, set: "iphone"),
    Slot(raw: "iPad 13-inch", folder: "iPad 13-inch", landscape: true, cornerRadius: 0.025, set: "ipad"),
    Slot(raw: "iPhone Duo outer", folder: "iPhone Duo", prefix: "outer", cornerRadius: 0.1, set: "duo"),
    Slot(raw: "iPhone Duo inner", folder: "iPhone Duo", prefix: "inner", landscape: true, cornerRadius: 0.035, set: "duo"),
    Slot(raw: "iPhone Duo half open", folder: "iPhone Duo", prefix: "half-open", cornerRadius: 0.05, set: "duo"),
    Slot(raw: "Apple TV", folder: "Apple TV", landscape: true, cornerRadius: 0.012, set: "tv"),
    Slot(raw: "Mac", folder: "Mac", landscape: true, cornerRadius: 0, set: "mac"),
]

struct Caption {
    let title: String
    let detail: String
}

/// By shot name; "<raw folder>/<shot>" overrides for one device.
let captions: [String: Caption] = [
    "01-home": Caption(title: "Your Jellyfin, beautifully", detail: "Your whole server, with what's next up front."),
    "02-show": Caption(title: "Every season, every episode", detail: "Pick up right where you left off."),
    "03-movie": Caption(title: "Choose your version", detail: "4K or 1080p, it's up to you."),
    "03-movies": Caption(title: "Your whole collection", detail: "Every film on your server, sorted how you like."),
    "04-downloads": Caption(title: "Downloads that keep going", detail: "Even with your phone asleep in your pocket."),
    "05-downloads": Caption(title: "Downloads that keep going", detail: "Even with your iPad asleep in your bag."),
    "05-search": Caption(title: "Find it in a moment", detail: "Search every movie, show and episode."),
    "03-player": Caption(title: "Plays almost anything", detail: "4K, HDR and lossless audio, straight from your server."),
    "04-player": Caption(title: "Plays almost anything", detail: "4K, HDR and lossless audio, straight from your server."),
    "iPhone Duo outer/01-home": Caption(title: "Folded, it's all there", detail: "The whole library on the outer display."),
    "iPhone Duo outer/02-show": Caption(title: "Every episode, one hand", detail: "Pick up right where you left off."),
    "iPhone Duo inner/01-home": Caption(title: "Open up to more", detail: "The inner display, edge to edge."),
    "iPhone Duo half open/01-player": Caption(title: "Made for iPhone Duo", detail: "Half open, the picture sits above the fold and your episodes below."),
    "Apple TV/01-home": Caption(title: "Made for the big screen", detail: "Your Jellyfin library, front and center."),
    "Mac/01-home": Caption(title: "At home on your Mac", detail: "Your Jellyfin library, in a window of its own."),
]

let headerPhrase = "Your Jellyfin, beautifully."

// MARK: Drawing

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [red, green, blue, alpha])!
}

/// The app icon's gradient.
let brandTop = color(0.13, 0.16, 0.52)
let brandBottom = color(0.60, 0.20, 0.86)

func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// An opaque Display P3 canvas with a top-left origin, written as a PNG without alpha.
func canvas(_ size: CGSize, to url: URL, _ draw: (CGContext) -> Void) throws {
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let result = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
}

/// Draws `image` upright in `rect` of a flipped context.
func draw(_ image: CGImage, in rect: CGRect, of context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

func background(_ size: CGSize, in context: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let gradient = CGGradient(colorsSpace: space, colors: [brandTop, brandBottom] as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: size.width * 0.25, y: 0), end: CGPoint(x: size.width * 0.75, y: size.height),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Soft light behind the caption and the screen.
    let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray, locations: nil)!
    let unit = max(size.width, size.height)
    context.drawRadialGradient(glow, startCenter: CGPoint(x: size.width * 0.5, y: 0), startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.5, y: 0), endRadius: unit * 0.6, options: [])
    let shade = CGGradient(colorsSpace: space, colors: [color(0.05, 0.03, 0.2, 0), color(0.05, 0.03, 0.2, 0.45)] as CFArray, locations: nil)!
    context.drawLinearGradient(shade, start: CGPoint(x: 0, y: size.height * 0.5), end: CGPoint(x: 0, y: size.height), options: [])
}

/// Draws `text` centered in `rect`, shrinking it until it fits; returns the height it took.
@discardableResult
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, in rect: CGRect) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineHeightMultiple = 1.02
    var fontSize = size / 0.95
    var attributed: NSAttributedString
    var bounds: CGRect
    repeat {
        fontSize *= 0.95
        attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style, .kern: -fontSize * 0.01,
        ])
        bounds = attributed.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
    } while bounds.height > rect.height
    attributed.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bounds.height), options: [.usesLineFragmentOrigin])
    return bounds.height
}

/// A screenshot under a caption, scaled to fill what's left of the canvas.
func frame(_ shot: CGImage, caption: Caption, slot: Slot, to url: URL) throws {
    let size = slot.canvas(for: CGSize(width: shot.width, height: shot.height))
    try canvas(size, to: url) { context in
        background(size, in: context)
        let unit = min(size.width, size.height)
        let side = size.width * 0.08
        var top = size.height * (slot.landscape ? 0.055 : 0.065)
        let titleSize = unit * (slot.landscape ? 0.058 : 0.085)
        top += text(caption.title, size: titleSize, weight: .bold, in: CGRect(x: side, y: top, width: size.width - side * 2, height: titleSize * 2.3))
        top += unit * 0.015
        top += text(caption.detail, size: titleSize * 0.48, weight: .medium, alpha: 0.82,
                    in: CGRect(x: side, y: top, width: size.width - side * 2, height: titleSize * 1.2))
        top += unit * (slot.landscape ? 0.045 : 0.06)
        let bottom = size.height * (slot.landscape ? 0.06 : 0.045)
        let available = CGSize(width: size.width - side * (slot.landscape ? 1.2 : 1.6), height: size.height - top - bottom)
        let scale = min(available.width / CGFloat(shot.width), available.height / CGFloat(shot.height))
        let screen = CGRect(x: (size.width - CGFloat(shot.width) * scale) / 2, y: top,
                            width: CGFloat(shot.width) * scale, height: CGFloat(shot.height) * scale)
        let radius = screen.width * slot.cornerRadius
        let outline = CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: unit * 0.012), blur: unit * 0.05, color: color(0.03, 0.01, 0.12, 0.6))
        if slot.cornerRadius > 0 {
            context.addPath(outline)
            context.setFillColor(color(0, 0, 0))
            context.fillPath()
        } else {
            draw(shot, in: screen, of: context)
        }
        context.restoreGState()
        if slot.cornerRadius > 0 {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            draw(shot, in: screen, of: context)
            context.restoreGState()
            // A hairline edge, as glass catches the light.
            context.addPath(outline)
            context.setStrokeColor(color(1, 1, 1, 0.22))
            context.setLineWidth(max(2, unit * 0.0025))
            context.strokePath()
        }
    }
}

// MARK: Header and search results

/// The showcase posters, in a stable order.
func posters() -> [CGImage] {
    ["movies", "tv"].flatMap { kind -> [URL] in
        let folder = mediaFolder.appending(path: kind)
        let titles = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return titles.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { $0.appending(path: "poster.jpg") }
    }
    .compactMap(image(at:))
}

/// The icon: the rounded V on the icon's gradient, in a rounded square.
func drawIcon(in rect: CGRect, of context: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let square = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: rect.width * 0.03), blur: rect.width * 0.12, color: color(0, 0, 0, 0.5))
    context.addPath(square)
    context.setFillColor(brandTop)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(square)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [brandTop, brandBottom] as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY),
                               end: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.maxY), options: [])
    context.restoreGState()
    // V.svg: a triangle with rounded joins, on a 1024 square.
    let unit = rect.width / 1024
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: rect.minX + 312 * unit, y: rect.minY + 322 * unit))
    triangle.addLine(to: CGPoint(x: rect.minX + 712 * unit, y: rect.minY + 322 * unit))
    triangle.addLine(to: CGPoint(x: rect.minX + 512 * unit, y: rect.minY + 742 * unit))
    triangle.closeSubpath()
    context.addPath(triangle)
    context.setFillColor(color(1, 1, 1))
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(92 * unit)
    context.setLineJoin(.round)
    context.drawPath(using: .fillStroke)
}

/// Rows of posters drifting across at a slight angle, dimmed behind the brand's colors, with
/// the icon, the name and the phrase in `safe`.
func marketing(_ size: CGSize, safe: CGRect, to url: URL) throws {
    let art = posters()
    guard !art.isEmpty else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: mediaFolder.path]) }
    try canvas(size, to: url) { context in
        background(size, in: context)
        context.saveGState()
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -0.12)
        let posterHeight = size.width * 0.16
        let posterWidth = posterHeight * 2 / 3
        let gap = posterWidth * 0.08
        let span = max(size.width, size.height) * 1.4
        var row = 0
        var y = -span / 2
        while y < span / 2 {
            var x = -span / 2 - CGFloat(row % 2) * posterWidth / 2
            var column = 0
            while x < span / 2 {
                let rect = CGRect(x: x, y: y, width: posterWidth, height: posterHeight)
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: posterWidth * 0.06, cornerHeight: posterWidth * 0.06, transform: nil))
                context.clip()
                // Five along per row down, so no poster sits next to itself.
                draw(art[(column + row * 5) % art.count], in: rect, of: context)
                context.restoreGState()
                column += 1
                x += posterWidth + gap
            }
            row += 1
            y += posterHeight + gap
        }
        context.restoreGState()
        // The brand over the art, darkest behind the words.
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        context.setFillColor(color(0.10, 0.08, 0.35, 0.55))
        context.fill(CGRect(origin: .zero, size: size))
        let center = CGPoint(x: safe.midX, y: safe.midY)
        let vignette = CGGradient(colorsSpace: space, colors: [color(0.06, 0.04, 0.22, 0.85), color(0.06, 0.04, 0.22, 0)] as CFArray,
                                  locations: nil)!
        context.drawRadialGradient(vignette, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: max(safe.width, safe.height) * 0.95, options: [])
        let iconSize = safe.height * 0.42
        drawIcon(in: CGRect(x: safe.midX - iconSize / 2, y: safe.minY + safe.height * 0.02, width: iconSize, height: iconSize), of: context)
        var top = safe.minY + iconSize + safe.height * 0.06
        top += text("vinnyfin", size: safe.height * 0.2, weight: .heavy, in: CGRect(x: safe.minX, y: top, width: safe.width, height: safe.height * 0.26))
        text(headerPhrase, size: safe.height * 0.09, weight: .medium, alpha: 0.88,
             in: CGRect(x: safe.minX, y: top + safe.height * 0.02, width: safe.width, height: safe.height * 0.14))
    }
}

// MARK: Run

func run() throws -> Int {
var written = 0
for slot in slots where sets.contains(slot.set) {
    let folder = rawFolder.appending(path: slot.raw)
    guard let shots = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
    // The slot's images from before go, so one no longer taken doesn't stay behind.
    let destination = outputFolder.appending(path: slot.folder)
    for old in (try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
    where old.pathExtension == "png" && (slot.prefix.isEmpty || old.lastPathComponent.hasPrefix("\(slot.prefix)-")) {
        try fileManager.removeItem(at: old)
    }
    for shot in shots.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = shot.deletingPathExtension().lastPathComponent
        guard let picture = image(at: shot) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: shot.path]) }
        guard let caption = captions["\(slot.raw)/\(name)"] ?? captions[name] else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "No caption for \(slot.raw)/\(name)"])
        }
        let file = (slot.prefix.isEmpty ? name : "\(slot.prefix)-\(name)") + ".png"
        try frame(picture, caption: caption, slot: slot, to: destination.appending(path: file))
        written += 1
    }
}
if sets.contains("marketing") {
    let folder = outputFolder.appending(path: "Header and Search Results")
    // Product page header, 21:9; search results, 3:2; one universal asset for both, 16:9. The safe
    // areas are the ones in Apple's templates.
    try marketing(CGSize(width: 3840, height: 1646), safe: CGRect(x: 1097, y: 493, width: 1646, height: 661),
                  to: folder.appending(path: "product-page-header.png"))
    try marketing(CGSize(width: 3840, height: 2560), safe: CGRect(x: 836, y: 765, width: 2168, height: 1030),
                  to: folder.appending(path: "search-results.png"))
    try marketing(CGSize(width: 5244, height: 2950), safe: CGRect(x: 1921, y: 660, width: 1402, height: 962),
                  to: folder.appending(path: "universal.png"))
    written += 3
}
return written
}

do {
    print("Wrote \(try run()) images to \(outputFolder.path)")
} catch {
    FileHandle.standardError.write(Data("Couldn't frame the screenshots: \(error.localizedDescription)\n".utf8))
    exit(1)
}
