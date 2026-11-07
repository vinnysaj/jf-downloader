// Draws vinnyfin's brand, all of it from the app icon, Vinnyfin/AppIcon.icon: the gradient in its
// icon.json and the V in its V.svg.
// Usage:
//   swift Compose.swift icons
//       Apple TV's and Vision Pro's icon layers, Apple TV's Top Shelf images, and the app's and the
//       widgets' accent color, the gradient's first, into their asset catalogs. Run it after changing
//       the icon; Xcode draws the other platforms' icons from AppIcon.icon.
//   swift Compose.swift <raw folder> <output folder> <media folder> [sets...]
//       Frames the raw captures for the App Store, each on the icon's gradient with a caption, at
//       the exact size of its App Store Connect slot, and with "marketing" among the sets draws the
//       product page header and search results artwork from the showcase posters. Written without
//       alpha.
import AppKit

let fileManager = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Ends the run with `message` on stderr.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: Slots and captions

struct Slot {
    /// The folder under Raw the captures come from.
    let raw: String
    /// The folder under the output, named for the App Store Connect slot. Several devices can
    /// share one; their shots' numbers set the order they go up in.
    let folder: String
    /// The pixel size the slot takes, turned to match the capture: sideways for one wider than tall.
    let size: CGSize
    /// The screen's corner radius as a fraction of its width; zero for a window with its own.
    let cornerRadius: CGFloat
    let set: String

    func canvas(for capture: CGSize) -> CGSize {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        return capture.width > capture.height ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }
}

let slots = [
    Slot(raw: "iPhone 6.9-inch", folder: "iPhone 6.9-inch", size: CGSize(width: 1320, height: 2868), cornerRadius: 0.14, set: "iphone"),
    Slot(raw: "iPad 13-inch", folder: "iPad 13-inch", size: CGSize(width: 2752, height: 2064), cornerRadius: 0.025, set: "ipad"),
    // One slot for both of iPhone Duo's displays, closed and open in turn.
    Slot(raw: "iPhone Duo outer", folder: "iPhone Duo", size: CGSize(width: 1398, height: 2034), cornerRadius: 0.1, set: "duo"),
    Slot(raw: "iPhone Duo inner", folder: "iPhone Duo", size: CGSize(width: 2853, height: 2007), cornerRadius: 0.035, set: "duo"),
    Slot(raw: "Apple TV", folder: "Apple TV", size: CGSize(width: 3840, height: 2160), cornerRadius: 0.012, set: "tv"),
    Slot(raw: "Apple Vision Pro", folder: "Apple Vision Pro", size: CGSize(width: 3840, height: 2160), cornerRadius: 0.012, set: "vision"),
    Slot(raw: "Mac", folder: "Mac", size: CGSize(width: 2880, height: 1800), cornerRadius: 0, set: "mac"),
]

/// By screen: a shot's name without its number, so "04-player" is "player".
let captions = [
    "home": "Your Jellyfin library",
    "show": "Pick up where you left off",
    "movie": "Choose 4K or 1080p",
    "movies": "Browse your movies",
    "player": "Jump to any chapter",
    "downloads": "Download whole seasons",
    "search": "Search your whole library",
    "remote": "Control your TV from your phone",
]

let headerPhrase = "For your Jellyfin server"

// MARK: Drawing

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [red, green, blue, alpha])!
}

/// The icon's gradient and the V over it, as AppIcon.icon has them.
struct Brand {
    let colors: [CGColor]
    /// Where the gradient starts and stops, as fractions of the width and height from the top left.
    let start: CGPoint
    let end: CGPoint
    let glyph: NSImage

    init(icon: URL) throws {
        struct File: Decodable {
            struct Point: Decodable { let x, y: CGFloat }
            struct Fill: Decodable {
                let colors: [String]
                let orientation: [String: Point]
                enum CodingKeys: String, CodingKey { case colors = "linear-gradient", orientation }
            }
            let fill: Fill
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: icon.appending(path: "icon.json")))
        colors = try file.fill.colors.map(Self.parsedColor)
        guard let start = file.fill.orientation["start"], let stop = file.fill.orientation["stop"] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "icon.json's gradient has no start and stop"])
        }
        self.start = CGPoint(x: start.x, y: start.y)
        end = CGPoint(x: stop.x, y: stop.y)
        let glyphFile = icon.appending(path: "Assets/V.svg")
        guard let glyph = NSImage(contentsOf: glyphFile) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: glyphFile.path]) }
        self.glyph = glyph
    }

    /// A color as Icon Composer writes one: "display-p3:0.47381,0.69075,0.46049,1.00000".
    static func parsedColor(_ text: String) throws -> CGColor {
        let parts = text.split(separator: ":")
        let components = parts.count == 2 ? parts[1].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) } : []
        guard parts.first == "display-p3", components.count == 4 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "icon.json has a color Compose.swift can't read: \(text)"])
        }
        return color(components[0], components[1], components[2], components[3])
    }

    /// The gradient across `rect`, carried on past its ends.
    func fill(_ rect: CGRect, of context: CGContext) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3)!, colors: colors as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX + rect.width * start.x, y: rect.minY + rect.height * start.y),
                                   end: CGPoint(x: rect.minX + rect.width * end.x, y: rect.minY + rect.height * end.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// The gradient's last color in deep shade, `alpha` opaque: for the dark at a screenshot's foot
    /// and to dim the art behind words.
    func shade(_ alpha: CGFloat) -> CGColor {
        let last = colors[colors.count - 1].components ?? [0, 0, 0, 1]
        return color(last[0] * 0.2, last[1] * 0.2, last[2] * 0.2, alpha)
    }

    /// Draws the V, `rect` being the square the icon fills.
    func drawGlyph(in rect: CGRect) {
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

let brand: Brand = {
    do {
        return try Brand(icon: root.appending(path: "Vinnyfin/AppIcon.icon"))
    } catch {
        fail("Couldn't read the icon: \(error.localizedDescription)")
    }
}()

/// The image at `url`, upright: a capture of a screen held sideways keeps the screen's own
/// orientation and says how to turn it.
func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    let upright = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, upright)
}

/// A Display P3 canvas with a top-left origin, written as a JPEG or a PNG by the file's extension:
/// opaque and without alpha unless it's a layer to go over others.
func canvas(_ size: CGSize, to url: URL, opaque: Bool = true, _ draw: (CGContext) -> Void) throws {
    let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: alpha.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context)
    NSGraphicsContext.restoreGraphicsState()
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let isJPEG = url.pathExtension == "jpg"
    guard let result = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, (isJPEG ? "public.jpeg" : "public.png") as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let options = isJPEG ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil
    CGImageDestinationAddImage(destination, result, options)
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
    brand.fill(CGRect(origin: .zero, size: size), of: context)
    // Soft light behind the caption and the screen.
    let glow = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray, locations: nil)!
    let unit = max(size.width, size.height)
    context.drawRadialGradient(glow, startCenter: CGPoint(x: size.width * 0.5, y: 0), startRadius: 0,
                               endCenter: CGPoint(x: size.width * 0.5, y: 0), endRadius: unit * 0.6, options: [])
    let shade = CGGradient(colorsSpace: space, colors: [brand.shade(0), brand.shade(0.45)] as CFArray, locations: nil)!
    context.drawLinearGradient(shade, start: CGPoint(x: 0, y: size.height * 0.5), end: CGPoint(x: 0, y: size.height), options: [])
}

/// `string` set centered, shrunk until it fits `room`, and the size it takes there: balanced, as
/// narrow as it goes without another line, so a caption over two lines doesn't leave one word on
/// the second.
func fitted(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, in room: CGSize) -> (NSAttributedString, CGSize) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineHeightMultiple = 1.02
    var fontSize = size / 0.95
    var attributed: NSAttributedString
    func height(at width: CGFloat) -> CGFloat {
        attributed.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
    }
    repeat {
        fontSize *= 0.95
        attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style, .kern: -fontSize * 0.01,
        ])
    } while height(at: room.width) > room.height
    let lines = height(at: room.width)
    var width = room.width
    while width > room.width * 0.4, height(at: width - room.width * 0.01) <= lines {
        width -= room.width * 0.01
    }
    return (attributed, CGSize(width: width, height: lines))
}

/// Draws `text` at the top of `rect`, centered across it and shrunk until it fits; returns the
/// height it took.
@discardableResult
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, in rect: CGRect) -> CGFloat {
    let (attributed, taken) = fitted(string, size: size, weight: weight, alpha: alpha, in: rect.size)
    attributed.draw(with: CGRect(x: rect.midX - taken.width / 2, y: rect.minY, width: taken.width, height: taken.height),
                    options: [.usesLineFragmentOrigin])
    return taken.height
}

/// A screenshot under a caption, scaled to fill what's left of the canvas.
func frame(_ shot: CGImage, caption: String, slot: Slot, to url: URL) throws {
    let size = slot.canvas(for: CGSize(width: shot.width, height: shot.height))
    try canvas(size, to: url) { context in
        background(size, in: context)
        let unit = min(size.width, size.height)
        let landscape = size.width > size.height
        let side = size.width * 0.08
        let titleSize = unit * (landscape ? 0.058 : 0.085)
        // The same room for every caption of a slot, two lines upright and one sideways, so each
        // shot's screen starts at the same height whatever its caption's length.
        let room = CGRect(x: side, y: size.height * (landscape ? 0.055 : 0.065), width: size.width - side * 2,
                          height: titleSize * (landscape ? 1.3 : 2.3))
        let (title, taken) = fitted(caption, size: titleSize, weight: .bold, in: room.size)
        title.draw(with: CGRect(x: room.midX - taken.width / 2, y: room.midY - taken.height / 2, width: taken.width, height: taken.height),
                   options: [.usesLineFragmentOrigin])
        let top = room.maxY + unit * (landscape ? 0.045 : 0.06)
        let bottom = size.height * (landscape ? 0.06 : 0.045)
        let available = CGSize(width: size.width - side * (landscape ? 1.2 : 1.6), height: size.height - top - bottom)
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

/// The showcase posters in `media`, in a stable order.
func posters(in media: URL) -> [CGImage] {
    ["movies", "tv"].flatMap { kind -> [URL] in
        let folder = media.appending(path: kind)
        let titles = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return titles.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { $0.appending(path: "poster.jpg") }
    }
    .compactMap(image(at:))
}

/// The icon in a rounded square, as the Home Screen shows it.
func drawIcon(in rect: CGRect, of context: CGContext) {
    let square = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: rect.width * 0.03), blur: rect.width * 0.12, color: color(0, 0, 0, 0.5))
    context.addPath(square)
    context.setFillColor(brand.colors[0])
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(square)
    context.clip()
    brand.fill(rect, of: context)
    context.restoreGState()
    brand.drawGlyph(in: rect)
}

/// Rows of posters drifting across at a slight angle, dimmed behind the brand's colors, with
/// the icon, the name and the phrase in `safe`.
func marketing(_ size: CGSize, safe: CGRect, media: URL, to url: URL) throws {
    let art = posters(in: media)
    guard !art.isEmpty else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: media.path]) }
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
        context.setFillColor(brand.shade(0.55))
        context.fill(CGRect(origin: .zero, size: size))
        let center = CGPoint(x: safe.midX, y: safe.midY)
        let vignette = CGGradient(colorsSpace: space, colors: [brand.shade(0.85), brand.shade(0)] as CFArray, locations: nil)!
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

// MARK: Icon layers and Top Shelf

/// The V in an Apple TV layer of `size`, at the height the platform's template gives it.
func tvGlyphSquare(_ size: CGSize) -> CGRect {
    let side = size.height * 1.2
    return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
}

/// The accent color the app and the widgets tint with, the gradient's first, as an asset catalog
/// color set in each of their catalogs.
func writeAccentColor() throws {
    guard let components = brand.colors[0].components, components.count == 4 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The gradient's first color isn't RGBA"])
    }
    let names = ["red", "green", "blue", "alpha"]
    let values = zip(names, components).map { "\"\($0)\" : \"\(String(format: "%.5f", $1))\"" }.joined(separator: ", ")
    let info = #""info" : { "author" : "xcode", "version" : 1 }"#
    let colorSet = """
    {
      "colors" : [
        { "color" : { "color-space" : "display-p3", "components" : { \(values) } }, "idiom" : "universal" }
      ],
      \(info)
    }

    """
    for catalog in ["Vinnyfin/Assets.xcassets", "DownloadsWidget/Assets.xcassets"].map({ root.appending(path: $0) }) {
        let folder = catalog.appending(path: "AccentColor.colorset")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(colorSet.utf8).write(to: folder.appending(path: "Contents.json"))
        let catalogContents = catalog.appending(path: "Contents.json")
        if !fileManager.fileExists(atPath: catalogContents.path) {
            try Data("{\n  \(info)\n}\n".utf8).write(to: catalogContents)
        }
    }
}

/// The art Xcode doesn't draw from AppIcon.icon: the layers of Vision Pro's and Apple TV's icons,
/// and Apple TV's Top Shelf images. Returns how many images it wrote.
func drawIconArt() throws -> Int {
    let catalog = root.appending(path: "Vinnyfin/Assets.xcassets")
    var written = 0
    // Vision Pro: the gradient, then the V on a layer of its own; the front layer stays empty.
    let vision = catalog.appending(path: "AppIcon.solidimagestack")
    let square = CGSize(width: 1024, height: 1024)
    try canvas(square, to: vision.appending(path: "Back.solidimagestacklayer/Content.imageset/Back.png")) {
        brand.fill(CGRect(origin: .zero, size: square), of: $0)
    }
    try canvas(square, to: vision.appending(path: "Middle.solidimagestacklayer/Content.imageset/Middle.png"), opaque: false) { _ in
        brand.drawGlyph(in: CGRect(origin: .zero, size: square))
    }
    written += 2
    // Apple TV: the gradient, the V's shadow, the V, for the Home Screen and the App Store.
    let tv = catalog.appending(path: "AppIcon TV.brandassets")
    let stacks: [(folder: String, files: [(suffix: String, size: CGSize)])] = [
        ("App Icon.imagestack", [("", CGSize(width: 400, height: 240)), ("@2x", CGSize(width: 800, height: 480))]),
        ("App Icon - App Store.imagestack", [("", CGSize(width: 1280, height: 768))]),
    ]
    for stack in stacks {
        for (suffix, size) in stack.files {
            let layer = { (name: String) in tv.appending(path: "\(stack.folder)/\(name).imagestacklayer/Content.imageset/\(name)\(suffix).png") }
            try canvas(size, to: layer("Back")) { brand.fill(CGRect(origin: .zero, size: size), of: $0) }
            try canvas(size, to: layer("Middle"), opaque: false) { context in
                // Only the shadow: the V is drawn off the canvas, its shadow cast back onto it.
                let away = size.width * 2
                context.setShadow(offset: CGSize(width: away, height: -size.height * 0.04), blur: size.height * 0.06, color: color(0, 0, 0, 0.45))
                brand.drawGlyph(in: tvGlyphSquare(size).offsetBy(dx: -away, dy: 0))
            }
            try canvas(size, to: layer("Front"), opaque: false) { _ in brand.drawGlyph(in: tvGlyphSquare(size)) }
            written += 3
        }
    }
    // Top Shelf: the V and the name on the gradient, at 1x and 2x.
    let shelves: [(folder: String, file: String, size: CGSize)] = [
        ("Top Shelf Image.imageset", "TopShelfImage", CGSize(width: 1920, height: 720)),
        ("Top Shelf Image Wide.imageset", "TopShelfImageWide", CGSize(width: 2320, height: 720)),
    ]
    for shelf in shelves {
        for (suffix, scale) in [("", CGFloat(1)), ("@2x", 2)] {
            let size = CGSize(width: shelf.size.width * scale, height: shelf.size.height * scale)
            try canvas(size, to: tv.appending(path: "\(shelf.folder)/\(shelf.file)\(suffix).png")) { context in
                brand.fill(CGRect(origin: .zero, size: size), of: context)
                let fontSize = size.height * 0.24
                let regular = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
                let font = regular.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? regular
                let name = NSAttributedString(string: "vinnyfin", attributes: [.font: font, .foregroundColor: NSColor.white])
                let nameSize = name.size()
                // V.svg's V spans the middle 48% of its square's width.
                let glyphSide = size.height * 0.9
                let glyphWidth = glyphSide * 0.48
                let gap = size.height * 0.08
                let left = (size.width - glyphWidth - gap - nameSize.width) / 2
                brand.drawGlyph(in: CGRect(x: left - glyphSide * 0.26, y: (size.height - glyphSide) / 2, width: glyphSide, height: glyphSide))
                name.draw(at: CGPoint(x: left + glyphWidth + gap, y: (size.height - nameSize.height) / 2))
            }
            written += 1
        }
    }
    return written
}

// MARK: Framing

func frameScreenshots(raw rawFolder: URL, output outputFolder: URL, media mediaFolder: URL, sets: Set<String>) throws -> Int {
var written = 0
let chosen = slots.filter { sets.contains($0.set) }
// The slots' images from before go, so one no longer taken doesn't stay behind.
for folder in Set(chosen.map(\.folder)) {
    let destination = outputFolder.appending(path: folder)
    for old in (try? fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
    where ["png", "jpg"].contains(old.pathExtension) {
        try fileManager.removeItem(at: old)
    }
}
for slot in chosen {
    let shots = try fileManager.contentsOfDirectory(at: rawFolder.appending(path: slot.raw), includingPropertiesForKeys: nil)
    for shot in shots.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = shot.deletingPathExtension().lastPathComponent
        guard let picture = image(at: shot) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: shot.path]) }
        let screen = String(name.drop { $0 != "-" }.dropFirst())
        guard let caption = captions[screen] else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "No caption for \(slot.raw)/\(name)"])
        }
        // Screenshots as high-quality JPEGs, a tenth of a PNG's size in the repo.
        let file = outputFolder.appending(path: slot.folder).appending(path: "\(name).jpg")
        // Devices sharing a slot number their shots apart.
        guard !fileManager.fileExists(atPath: file.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "Two shots for \(slot.folder) are named \(name)"])
        }
        try frame(picture, caption: caption, slot: slot, to: file)
        written += 1
    }
}
if sets.contains("marketing") {
    let folder = outputFolder.appending(path: "Header and Search Results")
    // Product page header, 21:9; search results, 3:2; one universal asset for both, 16:9. The safe
    // areas are the ones in Apple's templates.
    try marketing(CGSize(width: 3840, height: 1646), safe: CGRect(x: 1097, y: 493, width: 1646, height: 661), media: mediaFolder,
                  to: folder.appending(path: "product-page-header.png"))
    try marketing(CGSize(width: 3840, height: 2560), safe: CGRect(x: 836, y: 765, width: 2168, height: 1030), media: mediaFolder,
                  to: folder.appending(path: "search-results.png"))
    try marketing(CGSize(width: 5244, height: 2950), safe: CGRect(x: 1921, y: 660, width: 1402, height: 962), media: mediaFolder,
                  to: folder.appending(path: "universal.png"))
    written += 3
}
return written
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["icons"] {
    do {
        let written = try drawIconArt()
        try writeAccentColor()
        print("Wrote \(written) images and the accent color to the asset catalogs")
    } catch {
        fail("Couldn't draw the icon art: \(error.localizedDescription)")
    }
} else {
    guard arguments.count >= 3 else { fail("Usage: swift Compose.swift icons | <raw folder> <output folder> <media folder> [sets...]") }
    let output = URL(fileURLWithPath: arguments[1])
    do {
        let written = try frameScreenshots(raw: URL(fileURLWithPath: arguments[0]), output: output, media: URL(fileURLWithPath: arguments[2]),
                                           sets: Set(arguments.dropFirst(3)))
        print("Wrote \(written) images to \(output.path)")
    } catch {
        fail("Couldn't frame the screenshots: \(error.localizedDescription)")
    }
}
