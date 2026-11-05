// Generates the showcase library the App Store screenshots browse: original titles with drawn
// artwork, logos, metadata and still-picture videos, so nothing on screen belongs to anyone else.
// Pictures and metadata that already exist are kept, and videos still made the same way, so a
// second run only fills in what's missing or made differently.
// Usage: swift Showcase.swift <media folder>
import AppKit
import Synchronization

// MARK: Catalog

enum Scene { case mountains, ocean, dunes, city, space, forest, blobs }

enum TitleFont {
    case serif, sans, rounded, condensed

    func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: self == .serif ? .semibold : .black)
        let design: NSFontDescriptor.SystemDesign = switch self {
        case .serif: .serif
        case .rounded: .rounded
        case .sans, .condensed: .default
        }
        var descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        if self == .condensed {
            descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: -0.3,
                                                                 NSFontDescriptor.TraitKey.weight: NSFont.Weight.heavy]])
        }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    var tracking: CGFloat { self == .serif ? 0.04 : self == .condensed ? 0.02 : 0.08 }
}

struct Palette {
    /// Top to bottom.
    let sky: [String]
    let light: String
    /// Far to near.
    let land: [String]
}

struct Art {
    let scene: Scene
    let palette: Palette
    let font: TitleFont
}

/// A stretch of a film, with a picture of its own: the film's scene in another light.
struct Chapter {
    let title: String
    let minute: Int
    /// Nil for the film's own light, its backdrop.
    var palette: Palette?
}

struct Movie {
    let title: String
    let year: Int
    let genres: [String]
    let rating: String
    let score: Double
    let minutes: Int
    let tagline: String
    let plot: String
    let art: Art
    var versions: [String] = ["1080p"]
    /// From the start; a film without any is its backdrop throughout.
    var chapters: [Chapter] = []
}

struct Episode {
    let title: String
    let plot: String
}

struct Show {
    let title: String
    let year: Int
    let genres: [String]
    let rating: String
    let score: Double
    let minutes: Int
    let plot: String
    let art: Art
    let seasons: [[Episode]]
}

enum Palettes {
    static let dusk = Palette(sky: ["#1B1F3B", "#53354A", "#C8506A", "#FF9A7C"], light: "#FFE0B5",
                              land: ["#B06A80", "#7D4766", "#52304F", "#321F3A", "#1A1024"])
    static let sunsetSea = Palette(sky: ["#10243A", "#3B5B78", "#E59A6B", "#F7C27A"], light: "#FFF3D1",
                                   land: ["#5B6E86", "#2B4A63", "#173149", "#0B1C2C"])
    static let nightSea = Palette(sky: ["#03071E", "#0B1D3A", "#1F3D63", "#4A6C8F"], light: "#F4F6FF",
                                  land: ["#2A4363", "#16294A", "#0A1630", "#040A1A"])
    static let roseSea = Palette(sky: ["#2E1A47", "#7A3E6C", "#E07A8C", "#FCC6A8"], light: "#FFF0DE",
                                 land: ["#8E5A7E", "#5E3A62", "#3A2447", "#1E1330"])
    static let desert = Palette(sky: ["#3A1C71", "#B5577A", "#F29C74", "#FFD6A0"], light: "#FFF6E0",
                                land: ["#F0B486", "#D88B66", "#B0634F", "#7A4040", "#43232E"])
    static let ember = Palette(sky: ["#140A08", "#4A1A0F", "#B23A12", "#F59E5B"], light: "#FFE8C2",
                               land: ["#D5743F", "#A24A2A", "#6E2E1D", "#3F1A12", "#1C0B08"])
    static let glacier = Palette(sky: ["#0B1A33", "#274D7A", "#8DBBE0", "#DCEEFA"], light: "#FFFFFF",
                                 land: ["#C3DBEE", "#8FB3D3", "#6087B0", "#3B5D87", "#1C3354"])
    static let pine = Palette(sky: ["#0C1F18", "#24473B", "#6F9C82", "#D3E5CB"], light: "#F7F3E3",
                              land: ["#86A991", "#5A7F69", "#38594A", "#203B30", "#0E1E18"])
    static let goldField = Palette(sky: ["#1C2233", "#4E5A6B", "#C9A66B", "#F3DDA4"], light: "#FFF6DA",
                                   land: ["#A79A6A", "#7D7449", "#56512F", "#36331D", "#1B1A0E"])
    static let neon = Palette(sky: ["#0D0221", "#261447", "#5C1E8A", "#E0336B"], light: "#FDE2FF",
                              land: ["#3B2263", "#26164A", "#140B2C", "#08040F"])
    static let harbor = Palette(sky: ["#061826", "#0F3446", "#2D6A78", "#E3A65E"], light: "#FFE9C4",
                                land: ["#1D4D5C", "#123947", "#0A2532", "#04131C"])
    static let cosmos = Palette(sky: ["#02030A", "#0A0F2E", "#1D1450", "#3A1E6B"], light: "#FFD9A8",
                                land: ["#7B2FF7", "#F107A3", "#00C2FF", "#F4A261"])
    static let deepSpace = Palette(sky: ["#010208", "#05122B", "#0B2C55", "#1B4F7A"], light: "#CFE9FF",
                                   land: ["#2EC4FF", "#3CFFB5", "#7A5CFF", "#9AD0EC"])
    static let orchard = Palette(sky: ["#F6D6E8", "#D9C2F0", "#A9D6E5", "#F9E2AE"], light: "#FFFFFF",
                                 land: ["#FF8FAB", "#B388EB", "#72DDF7", "#FFD166", "#80ED99"])
    static let morning = Palette(sky: ["#2B3A55", "#7C8DB0", "#F2B880", "#FCE1B8"], light: "#FFF8E7",
                                 land: ["#C7A98B", "#9C8466", "#6C6248", "#3F4232", "#1F2419"])
}

let movies: [Movie] = [
    Movie(title: "The Quiet Meridian", year: 2025, genres: ["Drama", "Mystery"], rating: "PG-13", score: 8.4, minutes: 128,
          tagline: "Some maps only point home.",
          plot: "A surveyor sent to redraw a remote mountain border finds the old markers moved by someone who still lives along the line, and a reason to stay through the first snow.",
          art: Art(scene: .mountains, palette: Palettes.dusk, font: .serif), versions: ["2160p", "1080p"],
          chapters: [Chapter(title: "The Survey Office", minute: 0, palette: Palettes.morning),
                     Chapter(title: "Up the Pass", minute: 17, palette: Palettes.pine),
                     Chapter(title: "The Moved Markers", minute: 36, palette: Palettes.goldField),
                     Chapter(title: "The House on the Line", minute: 52),
                     Chapter(title: "Night Crossing", minute: 77, palette: Palettes.nightSea),
                     Chapter(title: "First Snow", minute: 98, palette: Palettes.glacier),
                     Chapter(title: "Some Maps Only Point Home", minute: 117, palette: Palettes.ember)]),
    Movie(title: "Saltwater Hymns", year: 2023, genres: ["Drama", "Music"], rating: "PG", score: 7.9, minutes: 112,
          tagline: "Every tide has a melody.",
          plot: "A church organist in a fishing town loses her hearing in one ear and learns the harbor's sounds all over again, one Sunday at a time.",
          art: Art(scene: .ocean, palette: Palettes.sunsetSea, font: .serif)),
    Movie(title: "Northbound Lanterns", year: 2024, genres: ["Adventure", "Family"], rating: "PG", score: 7.6, minutes: 104,
          tagline: "Follow the light north.",
          plot: "Two siblings carry their grandfather's lanterns through a forest that only opens at night, chasing a festival that may not happen without them.",
          art: Art(scene: .forest, palette: Palettes.pine, font: .sans)),
    Movie(title: "Glass Orchard", year: 2022, genres: ["Fantasy", "Romance"], rating: "PG", score: 7.2, minutes: 99,
          tagline: "Handle with care.",
          plot: "A glassblower inherits an orchard whose fruit rings like bells, and a neighbor determined to prove it's all a trick of the wind.",
          art: Art(scene: .blobs, palette: Palettes.orchard, font: .rounded)),
    Movie(title: "Signal Over Kestrel Bay", year: 2025, genres: ["Thriller"], rating: "R", score: 8.1, minutes: 118,
          tagline: "Someone is still transmitting.",
          plot: "When a decommissioned lighthouse starts broadcasting coordinates, a coast guard radio operator has one night to find out who is listening.",
          art: Art(scene: .ocean, palette: Palettes.nightSea, font: .condensed)),
    Movie(title: "Paper Comets", year: 2021, genres: ["Animation", "Family"], rating: "G", score: 8.0, minutes: 94,
          tagline: "Fold your wish. Let it fly.",
          plot: "A girl who folds paper comets on the roof of her apartment block is sure one of them made it to space. A very small astronaut is sure of it too.",
          art: Art(scene: .space, palette: Palettes.cosmos, font: .rounded)),
    Movie(title: "The Last Ferry to Ilsa", year: 2020, genres: ["Romance", "Drama"], rating: "PG-13", score: 7.4, minutes: 109,
          tagline: "One crossing left.",
          plot: "On the final season of an island ferry, its captain and the only regular passenger count down the crossings they have left.",
          art: Art(scene: .ocean, palette: Palettes.roseSea, font: .serif)),
    Movie(title: "Amber Cartographers", year: 2024, genres: ["Adventure"], rating: "PG-13", score: 7.7, minutes: 131,
          tagline: "The desert keeps its own records.",
          plot: "A team mapping shifting dunes discovers their survey lines rearranged every morning into a pattern no one on the team drew.",
          art: Art(scene: .dunes, palette: Palettes.desert, font: .sans)),
    Movie(title: "Neon Tidewater", year: 2026, genres: ["Science Fiction", "Thriller"], rating: "R", score: 8.2, minutes: 124,
          tagline: "The city floods at midnight.",
          plot: "In a coastal city that floods every night by design, a canal pilot is hired to ferry a passenger who doesn't appear on any registry.",
          art: Art(scene: .city, palette: Palettes.neon, font: .condensed)),
    Movie(title: "Low Orbit Lullaby", year: 2023, genres: ["Science Fiction", "Drama"], rating: "PG", score: 7.8, minutes: 101,
          tagline: "Sleep well, Earth.",
          plot: "The last crew member of a weather station in orbit records bedtime stories for the children who send her questions from below.",
          art: Art(scene: .space, palette: Palettes.deepSpace, font: .rounded)),
    Movie(title: "Winter at Halden Ridge", year: 2022, genres: ["Drama"], rating: "PG-13", score: 7.5, minutes: 116,
          tagline: "Snowed in. Opened up.",
          plot: "Five strangers waiting out a storm at a mountain hut discover they all came to Halden Ridge to scatter the same person's ashes.",
          art: Art(scene: .mountains, palette: Palettes.glacier, font: .serif)),
    Movie(title: "Copperline", year: 2019, genres: ["Western"], rating: "PG-13", score: 7.1, minutes: 107,
          tagline: "Ride the line. Hold the line.",
          plot: "A telegraph lineman in a dry canyon refuses to let the railroad cut the wire that keeps his town talking to the world.",
          art: Art(scene: .dunes, palette: Palettes.ember, font: .condensed)),
]

let shows: [Show] = [
    Show(title: "Port Ellery", year: 2024, genres: ["Drama"], rating: "TV-14", score: 8.6, minutes: 52,
         plot: "A harbor town at the edge of the map keeps its secrets in the fog. When the night ferry runs aground, its new harbormaster starts asking which ones are worth keeping.",
         art: Art(scene: .city, palette: Palettes.harbor, font: .serif),
         seasons: [
            [Episode(title: "The Night Ferry", plot: "A new harbormaster arrives the same night the ferry runs aground on rocks it has passed for forty years."),
             Episode(title: "Low Tide", plot: "The water pulls back further than anyone remembers, and something under the pier comes into view."),
             Episode(title: "What the Gulls Saw", plot: "An inquest at the fish market turns into a town meeting nobody wanted."),
             Episode(title: "Breakwater", plot: "A storm forces the town to choose between saving the boats and saving the archive."),
             Episode(title: "Fog Signals", plot: "The foghorn sounds a pattern only the oldest sailors recognize."),
             Episode(title: "All Hands", plot: "Every boat in the harbor sets out at once, and the harbormaster has to decide whom to follow.")],
            [Episode(title: "Return Passage", plot: "A year later the ferry runs again, with a passenger list that doesn't add up."),
             Episode(title: "Harbor Fees", plot: "A developer offers to pay every debt in town, for a price."),
             Episode(title: "Salt and Iron", plot: "The shipyard reopens to build something no one will name."),
             Episode(title: "The Keeper's Ledger", plot: "The lighthouse logbooks show ships that never reached port."),
             Episode(title: "Undertow", plot: "An old friendship breaks under the weight of what the ledger proves."),
             Episode(title: "Open Water", plot: "The town sails out to meet whatever has been waiting past the breakwater.")],
         ]),
    Show(title: "Starfall Station", year: 2025, genres: ["Science Fiction"], rating: "TV-PG", score: 8.3, minutes: 44,
         plot: "Aboard a mining station orbiting a dying star, a crew of twelve learns their relief ship isn't coming, and that the star has started answering their signals.",
         art: Art(scene: .space, palette: Palettes.deepSpace, font: .sans),
         seasons: [
            [Episode(title: "Arrival Window", plot: "The relief ship misses its arrival window, and the station's clocks start disagreeing."),
             Episode(title: "Dead Reckoning", plot: "With navigation dark, the pilot plots a course by the star's flares."),
             Episode(title: "Quiet Hours", plot: "Someone keeps waking the crew at the same minute every night."),
             Episode(title: "Docking Rights", plot: "An empty shuttle requests permission to dock."),
             Episode(title: "The Long Dark", plot: "The star dims, and the crew has one night to decide what to send home.")],
            [Episode(title: "Second Orbit", plot: "The station drifts into a new orbit no one programmed."),
             Episode(title: "Signal Loss", plot: "Contact with Earth returns, but the voices are years old."),
             Episode(title: "Ghost Cargo", plot: "The ore holds are full of something the drills never touched."),
             Episode(title: "Perihelion", plot: "The closest pass to the star brings the crew face to face with its message."),
             Episode(title: "Starfall", plot: "The station falls toward the light, and the crew finally answers.")],
         ]),
    Show(title: "The Long Field", year: 2023, genres: ["Mystery", "Drama"], rating: "TV-14", score: 8.0, minutes: 48,
         plot: "In a farming valley where the harvest has never failed, a scarecrow appears overnight in every field, and a returning daughter is the only one who knows who made them.",
         art: Art(scene: .forest, palette: Palettes.goldField, font: .serif),
         seasons: [
            [Episode(title: "The Scarecrow Line", plot: "A daughter comes home for the harvest and finds the valley lined with scarecrows."),
             Episode(title: "Harvest Moon", plot: "The town's oldest tradition goes ahead without the family that started it."),
             Episode(title: "Fence Posts", plot: "A boundary dispute uncovers a deed signed by someone who never lived."),
             Episode(title: "The Well", plot: "The town well runs dry for the first time in a century."),
             Episode(title: "Crows at Dusk", plot: "The birds stop coming to one field, and its owner stops answering the door."),
             Episode(title: "Burn Season", plot: "A controlled burn gets away from the valley, and from the truth."),
             Episode(title: "Seed Vault", plot: "The co-op's seed vault holds one jar labeled with her name."),
             Episode(title: "First Frost", plot: "The harvest comes in, and the scarecrows come down, all but one.")],
         ]),
    Show(title: "Small Mountain Kitchens", year: 2022, genres: ["Documentary", "Food"], rating: "TV-G", score: 8.8, minutes: 28,
         plot: "A cook travels to tiny kitchens high in the mountains to learn one dish from each, and the stories that keep it alive.",
         art: Art(scene: .mountains, palette: Palettes.morning, font: .rounded),
         seasons: [
            [Episode(title: "Bread at Altitude", plot: "Above the tree line, a baker shows why her loaves need a day longer than anyone else's."),
             Episode(title: "The Cheese Caves", plot: "A family ages cheese in caves their great-grandparents dug by hand."),
             Episode(title: "Wild Herbs", plot: "A forager's morning walk becomes the evening's soup."),
             Episode(title: "Smoke and Salt", plot: "A smokehouse that has run without pause for sixty years."),
             Episode(title: "Orchard Pies", plot: "The last orchard on the pass and the pies that pay for it."),
             Episode(title: "The Winter Pantry", plot: "Everything a mountain kitchen puts away to last until spring.")],
         ]),
]

// MARK: Drawing

struct Random {
    private var state: UInt64

    init(_ text: String) {
        state = text.unicodeScalars.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }

    mutating func next(_ range: ClosedRange<Double>) -> CGFloat {
        CGFloat(range.lowerBound + next() * (range.upperBound - range.lowerBound))
    }
}

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func mix(_ first: String, _ second: String, _ amount: CGFloat) -> CGColor {
    let a = color(first).components ?? [0, 0, 0, 1]
    let b = color(second).components ?? [0, 0, 0, 1]
    return CGColor(srgbRed: a[0] + (b[0] - a[0]) * amount, green: a[1] + (b[1] - a[1]) * amount,
                   blue: a[2] + (b[2] - a[2]) * amount, alpha: 1)
}

/// Paints the band between `start` and `end`, or with `extending`, everything the clip allows.
func linear(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint, extending: Bool = false) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: extending ? [.drawsBeforeStartLocation, .drawsAfterEndLocation] : [])
}

func glow(_ context: CGContext, at center: CGPoint, radius: CGFloat, _ hex: String, strength: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [color(hex, alpha: strength), color(hex, alpha: strength * 0.35), color(hex, alpha: 0)] as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.35, 1]) else { return }
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// A ridge line across the width by midpoint displacement, as heights above the bottom.
func ridge(width: CGFloat, base: CGFloat, roughness: CGFloat, random: inout Random) -> [CGPoint] {
    var heights: [CGFloat] = [base + random.next(-1...1) * roughness, base + random.next(-1...1) * roughness]
    var spread = roughness
    for _ in 0..<8 {
        var next: [CGFloat] = []
        for index in 0..<(heights.count - 1) {
            next.append(heights[index])
            next.append((heights[index] + heights[index + 1]) / 2 + random.next(-1...1) * spread)
        }
        next.append(heights[heights.count - 1])
        heights = next
        spread *= 0.55
    }
    return heights.enumerated().map { CGPoint(x: width * CGFloat($0.offset) / CGFloat(heights.count - 1), y: $0.element) }
}

func fill(_ context: CGContext, below points: [CGPoint], _ fillColor: CGColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: -10))
    for point in points { path.addLine(to: point) }
    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: -10))
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(fillColor)
    context.fillPath()
}

func stars(_ context: CGContext, size: CGSize, count: Int, above floor: CGFloat, random: inout Random) {
    for _ in 0..<count {
        let point = CGPoint(x: random.next(0...1) * size.width, y: floor + random.next(0...1) * (size.height - floor))
        let radius = random.next(0.3...1.4) * size.width / 1400
        context.setFillColor(CGColor(gray: 1, alpha: random.next(0.25...0.9)))
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// Draws `art` filling `size`, in a context whose origin is the bottom left.
func drawScene(_ art: Art, size: CGSize, seed: String, in context: CGContext) {
    var random = Random(seed)
    let palette = art.palette
    let width = size.width, height = size.height
    let unit = min(width, height)
    linear(context, palette.sky.map { color($0) }, from: CGPoint(x: 0, y: height), to: CGPoint(x: 0, y: height * 0.25), extending: true)
    switch art.scene {
    case .mountains, .forest:
        let sun = CGPoint(x: width * random.next(0.25...0.75), y: height * random.next(0.5...0.68))
        glow(context, at: sun, radius: unit * 0.7, palette.light, strength: 0.55)
        context.setFillColor(color(palette.light, alpha: 0.95))
        let sunRadius = unit * random.next(0.06...0.09)
        context.fillEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
        let layers = palette.land
        for (index, hex) in layers.enumerated() {
            let depth = CGFloat(index) / CGFloat(layers.count - 1)
            let base = height * (0.5 - depth * 0.36)
            let points = ridge(width: width, base: base, roughness: height * (art.scene == .mountains ? 0.16 - depth * 0.06 : 0.04),
                               random: &random)
            fill(context, below: points, color(hex))
            if art.scene == .forest {
                // Pines along the ridge, smaller and fainter further back.
                let treeHeight = height * (0.05 + depth * 0.09)
                var x: CGFloat = -treeHeight
                while x < width + treeHeight {
                    let ground = points[min(points.count - 1, max(0, Int(x / width * CGFloat(points.count - 1))))].y
                    let tall = treeHeight * random.next(0.7...1.3)
                    let half = tall * 0.22
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: x - half, y: ground - 2))
                    path.addLine(to: CGPoint(x: x, y: ground + tall))
                    path.addLine(to: CGPoint(x: x + half, y: ground - 2))
                    path.closeSubpath()
                    context.addPath(path)
                    context.setFillColor(color(hex))
                    context.fillPath()
                    x += half * random.next(0.9...1.8)
                }
            }
            // Haze between layers, thicker further back.
            linear(context, [color(palette.sky.last!, alpha: 0.28 * (1 - depth)), color(palette.sky.last!, alpha: 0)],
                   from: CGPoint(x: 0, y: base - height * 0.05), to: CGPoint(x: 0, y: base - height * 0.16))
        }
    case .ocean:
        let horizon = height * random.next(0.36...0.44)
        let sun = CGPoint(x: width * random.next(0.3...0.7), y: horizon + height * random.next(0.04...0.14))
        if palette.sky.first == Palettes.nightSea.sky.first { stars(context, size: size, count: 260, above: horizon, random: &random) }
        glow(context, at: sun, radius: unit * 0.8, palette.light, strength: 0.6)
        context.setFillColor(color(palette.light, alpha: 0.95))
        let sunRadius = unit * 0.075
        context.fillEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
        // A far headland on the horizon.
        let headland = ridge(width: width, base: horizon + height * 0.012, roughness: height * 0.02, random: &random)
            .map { CGPoint(x: $0.x, y: $0.x < width * 0.45 ? $0.y : horizon) }
        fill(context, below: headland, color(palette.land[0]))
        context.setFillColor(color(palette.land[1]))
        context.fill(CGRect(x: 0, y: 0, width: width, height: horizon))
        linear(context, palette.land.dropFirst().map { color($0) }, from: CGPoint(x: 0, y: horizon), to: .zero)
        // The sun's path on the water, and swells.
        for row in 0..<70 {
            let depth = CGFloat(row) / 70
            let y = horizon - pow(depth, 1.6) * horizon
            let spread = width * (0.03 + depth * 0.22)
            let segmentWidth = spread * random.next(0.2...0.9)
            let x = sun.x - spread / 2 + random.next(0...1) * (spread - segmentWidth)
            context.setFillColor(color(palette.light, alpha: 0.55 * (1 - depth * 0.7)))
            context.fill(CGRect(x: x, y: y, width: segmentWidth, height: max(1.5, height * 0.0025 * (1 + depth * 3))))
        }
        context.setLineWidth(max(1, unit * 0.002))
        for row in 0..<18 {
            let depth = CGFloat(row) / 18
            let y = horizon - pow(depth, 1.4) * horizon * 0.95
            let path = CGMutablePath()
            let phase = random.next(0...6.28)
            path.move(to: CGPoint(x: 0, y: y))
            for step in stride(from: CGFloat(0), through: width, by: width / 80) {
                path.addLine(to: CGPoint(x: step, y: y + sin(step / width * 18 + phase) * height * 0.003 * (1 + depth * 4)))
            }
            context.addPath(path)
            context.setStrokeColor(color(palette.light, alpha: 0.07 + depth * 0.05))
            context.strokePath()
        }
    case .dunes:
        let sun = CGPoint(x: width * random.next(0.2...0.8), y: height * random.next(0.55...0.7))
        glow(context, at: sun, radius: unit * 0.75, palette.light, strength: 0.6)
        context.setFillColor(color(palette.light, alpha: 0.95))
        let sunRadius = unit * 0.1
        context.fillEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
        for (index, hex) in palette.land.enumerated() {
            let depth = CGFloat(index) / CGFloat(palette.land.count - 1)
            let base = height * (0.46 - depth * 0.34)
            let crest = width * random.next(0.15...0.85)
            let rise = height * random.next(0.06...0.14)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -width * 0.1, y: base))
            path.addCurve(to: CGPoint(x: crest, y: base + rise),
                          control1: CGPoint(x: crest * 0.4, y: base + rise * 0.2), control2: CGPoint(x: crest * 0.75, y: base + rise))
            path.addCurve(to: CGPoint(x: width * 1.1, y: base - rise * 0.3),
                          control1: CGPoint(x: crest + (width - crest) * 0.3, y: base + rise * 0.9),
                          control2: CGPoint(x: crest + (width - crest) * 0.7, y: base))
            path.addLine(to: CGPoint(x: width * 1.1, y: -10))
            path.addLine(to: CGPoint(x: -width * 0.1, y: -10))
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            // Lit on the sun's side, in shadow past the crest.
            let lit = mix(hex, palette.light, 0.25)
            let shade = mix(hex, "#000000", 0.25)
            linear(context, sun.x < crest ? [lit, color(hex), shade] : [shade, color(hex), lit],
                   from: CGPoint(x: crest - width * 0.3, y: 0), to: CGPoint(x: crest + width * 0.3, y: 0), extending: true)
            context.restoreGState()
        }
    case .city:
        stars(context, size: size, count: 180, above: height * 0.5, random: &random)
        let moon = CGPoint(x: width * random.next(0.6...0.85), y: height * random.next(0.68...0.8))
        glow(context, at: moon, radius: unit * 0.45, palette.light, strength: 0.4)
        context.setFillColor(color(palette.light))
        let moonRadius = unit * 0.05
        context.fillEllipse(in: CGRect(x: moon.x - moonRadius, y: moon.y - moonRadius, width: moonRadius * 2, height: moonRadius * 2))
        let waterline = height * 0.3
        let windows = ["#FFD166", "#FFB4A2", "#9BF6FF"]
        for (index, hex) in palette.land.prefix(3).enumerated() {
            let depth = CGFloat(index) / 2
            var x: CGFloat = -width * 0.02
            while x < width {
                let buildingWidth = width * random.next(0.03...0.08) * (1 + depth * 0.4)
                let buildingHeight = height * random.next(0.08...0.32) * (1.15 - depth * 0.35)
                let rect = CGRect(x: x, y: waterline, width: buildingWidth, height: buildingHeight)
                context.setFillColor(color(hex))
                context.fill(rect)
                let cell = buildingWidth / 6
                var windowY = waterline + cell
                while windowY < waterline + buildingHeight - cell {
                    var windowX = x + cell * 0.8
                    while windowX < x + buildingWidth - cell {
                        if random.next() < 0.35 {
                            context.setFillColor(color(windows[Int(random.next() * 2.99)], alpha: 0.5 + 0.4 * (1 - depth)))
                            context.fill(CGRect(x: windowX, y: windowY, width: cell * 0.55, height: cell * 0.7))
                        }
                        windowX += cell * 1.3
                    }
                    windowY += cell * 1.5
                }
                x += buildingWidth + width * random.next(0...0.012)
            }
        }
        // Water with the lights' reflections.
        linear(context, [color(palette.land[2]), color(palette.land[3])], from: CGPoint(x: 0, y: waterline), to: .zero)
        for _ in 0..<160 {
            let x = random.next(0...1) * width
            let depth = random.next(0...1)
            let y = waterline - depth * waterline * 0.9
            context.setFillColor(color(windows[Int(random.next() * 2.99)], alpha: 0.35 * (1 - depth)))
            context.fill(CGRect(x: x, y: y, width: width * random.next(0.01...0.04), height: max(1.5, height * 0.003)))
        }
        glow(context, at: CGPoint(x: moon.x, y: waterline * 0.6), radius: unit * 0.3, palette.light, strength: 0.15)
    case .space:
        stars(context, size: size, count: 900, above: 0, random: &random)
        for (index, hex) in palette.land.prefix(3).enumerated() {
            let center = CGPoint(x: width * random.next(0.1...0.9), y: height * random.next(0.2...0.85))
            glow(context, at: center, radius: unit * random.next(0.35...0.7), hex, strength: index == 0 ? 0.45 : 0.32)
        }
        let planet = CGPoint(x: width * random.next(0.25...0.75), y: height * random.next(0.25...0.45))
        let planetRadius = unit * random.next(0.17...0.24)
        let planetRect = CGRect(x: planet.x - planetRadius, y: planet.y - planetRadius, width: planetRadius * 2, height: planetRadius * 2)
        let ringColor = color(palette.light, alpha: 0.55)
        let ring = CGRect(x: planet.x - planetRadius * 1.9, y: planet.y - planetRadius * 0.42, width: planetRadius * 3.8, height: planetRadius * 0.84)
        // The ring's far half, the planet, then the near half over it.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: planet.y, width: width, height: height))
        context.setStrokeColor(ringColor)
        context.setLineWidth(planetRadius * 0.07)
        context.strokeEllipse(in: ring)
        context.restoreGState()
        context.saveGState()
        context.addEllipse(in: planetRect)
        context.clip()
        linear(context, [color(palette.land[3]), mix(palette.land[3], "#000000", 0.75)],
               from: CGPoint(x: planetRect.minX, y: planetRect.maxY), to: CGPoint(x: planetRect.maxX, y: planetRect.minY), extending: true)
        for band in 0..<6 {
            let y = planetRect.minY + planetRect.height * CGFloat(band) / 6 + random.next(0...1) * planetRadius * 0.1
            context.setFillColor(CGColor(gray: 1, alpha: 0.06))
            context.fill(CGRect(x: planetRect.minX, y: y, width: planetRect.width, height: planetRadius * 0.08))
        }
        context.restoreGState()
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: planet.y))
        context.setStrokeColor(ringColor)
        context.setLineWidth(planetRadius * 0.07)
        context.strokeEllipse(in: ring)
        context.restoreGState()
    case .blobs:
        for hex in palette.land {
            let center = CGPoint(x: width * random.next(-0.1...1.1), y: height * random.next(-0.1...1.1))
            glow(context, at: center, radius: unit * random.next(0.5...0.9), hex, strength: 0.85)
        }
        // A few glass spheres catching the light.
        for _ in 0..<7 {
            let radius = unit * random.next(0.03...0.11)
            let center = CGPoint(x: width * random.next(0.1...0.9), y: height * random.next(0.15...0.85))
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(CGColor(gray: 1, alpha: 0.18))
            context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
            context.setLineWidth(max(1, radius * 0.05))
            context.strokeEllipse(in: rect.insetBy(dx: radius * 0.04, dy: radius * 0.04))
            glow(context, at: CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.4), radius: radius * 0.5, "#FFFFFF", strength: 0.8)
        }
    }
    // Film grain, so flat gradients don't band.
    for _ in 0..<Int(width * height / 250) {
        context.setFillColor(CGColor(gray: random.next() < 0.5 ? 0 : 1, alpha: 0.045))
        context.fill(CGRect(x: random.next(0...1) * width, y: random.next(0...1) * height, width: 1.5, height: 1.5))
    }
}

func drawTitle(_ title: String, font: TitleFont, in rect: CGRect, maxSize: CGFloat, shadow: Bool) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    style.lineHeightMultiple = 0.92
    let string = font == .serif ? title : title.uppercased()
    var size = maxSize / 0.94
    var text: NSAttributedString
    // Shrinks until it fits, without breaking a word or running past three lines.
    repeat {
        size *= 0.94
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font.font(size: size), .foregroundColor: NSColor.white, .paragraphStyle: style, .kern: size * font.tracking,
        ]
        text = NSAttributedString(string: string, attributes: attributes)
    } while text.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height > rect.height
        || string.split(separator: " ").contains { NSAttributedString(string: String($0), attributes: text.attributes(at: 0, effectiveRange: nil)).size().width > rect.width }
    let box = text.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
    if shadow {
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        glyphShadow.shadowBlurRadius = maxSize * 0.18
        glyphShadow.shadowOffset = NSSize(width: 0, height: -maxSize * 0.04)
        glyphShadow.set()
    }
    text.draw(with: NSRect(x: rect.minX, y: rect.midY - box.height / 2, width: rect.width, height: box.height),
              options: [.usesLineFragmentOrigin])
}

func render(size: CGSize, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    draw(graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    let type: NSBitmapImageRep.FileType = url.pathExtension == "png" ? .png : .jpeg
    guard let data = bitmap.representation(using: type, properties: [.compressionFactor: 0.9]) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    try data.write(to: url)
}

func poster(_ title: String, year: Int, art: Art, to url: URL) throws {
    let size = CGSize(width: 1000, height: 1500)
    try write(render(size: size) { context in
        drawScene(art, size: size, seed: title + "poster", in: context)
        linear(context, [CGColor(gray: 0, alpha: 0.75), CGColor(gray: 0, alpha: 0)], from: .zero, to: CGPoint(x: 0, y: size.height * 0.45))
        drawTitle(title, font: art.font, in: CGRect(x: 70, y: 150, width: size.width - 140, height: 330), maxSize: 120, shadow: true)
        let credit = NSAttributedString(string: "\(year)", attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.75), .kern: 6,
        ])
        credit.draw(at: NSPoint(x: (size.width - credit.size().width) / 2, y: 90))
    }, to: url)
}

func backdrop(seed: String, art: Art, size: CGSize = CGSize(width: 1920, height: 1080), to url: URL) throws {
    try write(render(size: size) { drawScene(art, size: size, seed: seed, in: $0) }, to: url)
}

func logo(_ title: String, art: Art, to url: URL) throws {
    let size = CGSize(width: 1400, height: 540)
    try write(render(size: size) { _ in
        drawTitle(title, font: art.font, in: CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 20), maxSize: 230, shadow: true)
    }, to: url)
}

// MARK: Files

let media = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "media")
let fileManager = FileManager.default

func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
}

func writeIfMissing(_ url: URL, _ make: (URL) throws -> Void) throws {
    guard !fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try make(url)
}

/// A video of still pictures for the given length, one for each chapter or one throughout:
/// Jellyfin reads the runtime and the chapters from the file, and a still at one frame a second
/// stays a few megabytes however long it runs.
struct Encode {
    struct Scene {
        /// Seconds in.
        let start: Int
        /// The chapter's; nil in a video without chapters.
        let title: String?
        let still: Still
    }

    enum Still {
        /// A picture drawn for the library already, as a backdrop.
        case file(URL)
        /// Drawn for the video alone.
        case drawn(Art, seed: String)
    }

    /// The codecs every video is made with, at one frame a second.
    static let settings = ["-c:v", "libx264", "-preset", "veryfast", "-tune", "stillimage", "-crf", "26", "-g", "120",
                           "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "6k", "-metadata:s:a:0", "language=eng"]

    let scenes: [Scene]
    let output: URL
    let seconds: Int
    let resolution: String

    /// Where each scene ends, in seconds.
    func end(of index: Int) -> Int {
        index + 1 < scenes.count ? scenes[index + 1].start : seconds
    }

    /// How the video is made, kept beside it, so one made another way is made again.
    var recipe: String {
        let scenes = scenes.map { scene in
            let still = switch scene.still {
            case .file(let url): url.lastPathComponent
            case .drawn(let art, let seed): "\(seed) \(art)"
            }
            return "\(scene.start) \(scene.title ?? "") \(still)"
        }
        return ([Self.settings.joined(separator: " "), "\(resolution) \(seconds)"] + scenes).joined(separator: "\n")
    }

    var recipeFile: URL { output.deletingLastPathComponent().appending(path: ".\(output.lastPathComponent).recipe") }

    var isCurrent: Bool {
        fileManager.fileExists(atPath: output.path) && (try? String(contentsOf: recipeFile, encoding: .utf8)) == recipe
    }

    /// The chapters in FFmpeg's metadata format, which escapes `=`, `;`, `#` and `\` in values.
    var chapterMetadata: String {
        let chapters = scenes.enumerated().compactMap { index, scene -> String? in
            guard let title = scene.title else { return nil }
            let value = title.reduce(into: "") { escaped, character in
                if "=;#\\".contains(character) { escaped.append("\\") }
                escaped.append(character)
            }
            return "[CHAPTER]\nTIMEBASE=1/1\nSTART=\(scene.start)\nEND=\(end(of: index))\ntitle=\(value)"
        }
        return ([";FFMETADATA1"] + chapters).joined(separator: "\n") + "\n"
    }
}

var encodes: [Encode] = []

for movie in movies {
    let folder = media.appending(path: "movies/\(movie.title) (\(movie.year))")
    try writeIfMissing(folder.appending(path: "poster.jpg")) { try poster(movie.title, year: movie.year, art: movie.art, to: $0) }
    try writeIfMissing(folder.appending(path: "backdrop.jpg")) { try backdrop(seed: movie.title, art: movie.art, to: $0) }
    try writeIfMissing(folder.appending(path: "logo.png")) { try logo(movie.title, art: movie.art, to: $0) }
    try writeIfMissing(folder.appending(path: "movie.nfo")) { url in
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <movie>
          <title>\(escaped(movie.title))</title>
          <year>\(movie.year)</year>
          <premiered>\(movie.year)-05-14</premiered>
          <tagline>\(escaped(movie.tagline))</tagline>
          <plot>\(escaped(movie.plot))</plot>
        \(movie.genres.map { "  <genre>\(escaped($0))</genre>" }.joined(separator: "\n"))
          <mpaa>\(movie.rating)</mpaa>
          <rating>\(movie.score)</rating>
          <lockdata>true</lockdata>
        </movie>
        """.write(to: url, atomically: true, encoding: .utf8)
    }
    let backdrop = Encode.Still.file(folder.appending(path: "backdrop.jpg"))
    let scenes = movie.chapters.isEmpty ? [Encode.Scene(start: 0, title: nil, still: backdrop)] : movie.chapters.map { chapter in
        let still = chapter.palette.map { palette in
            Encode.Still.drawn(Art(scene: movie.art.scene, palette: palette, font: movie.art.font), seed: "\(movie.title) \(chapter.title)")
        }
        return Encode.Scene(start: chapter.minute * 60, title: chapter.title, still: still ?? backdrop)
    }
    for version in movie.versions {
        let name = movie.versions.count > 1 ? "\(movie.title) (\(movie.year)) - \(version).mkv" : "\(movie.title) (\(movie.year)).mkv"
        encodes.append(Encode(scenes: scenes, output: folder.appending(path: name),
                              seconds: movie.minutes * 60, resolution: version == "2160p" ? "3840:2160" : "1920:1080"))
    }
}

for show in shows {
    let folder = media.appending(path: "tv/\(show.title) (\(show.year))")
    try writeIfMissing(folder.appending(path: "poster.jpg")) { try poster(show.title, year: show.year, art: show.art, to: $0) }
    try writeIfMissing(folder.appending(path: "backdrop.jpg")) { try backdrop(seed: show.title, art: show.art, to: $0) }
    try writeIfMissing(folder.appending(path: "logo.png")) { try logo(show.title, art: show.art, to: $0) }
    try writeIfMissing(folder.appending(path: "tvshow.nfo")) { url in
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <tvshow>
          <title>\(escaped(show.title))</title>
          <year>\(show.year)</year>
          <premiered>\(show.year)-09-21</premiered>
          <plot>\(escaped(show.plot))</plot>
        \(show.genres.map { "  <genre>\(escaped($0))</genre>" }.joined(separator: "\n"))
          <mpaa>\(show.rating)</mpaa>
          <rating>\(show.score)</rating>
          <lockdata>true</lockdata>
        </tvshow>
        """.write(to: url, atomically: true, encoding: .utf8)
    }
    for (seasonIndex, episodes) in show.seasons.enumerated() {
        let season = seasonIndex + 1
        try writeIfMissing(folder.appending(path: String(format: "season%02d-poster.jpg", season))) {
            try poster("Season \(season)", year: show.year + seasonIndex, art: show.art, to: $0)
        }
        for (episodeIndex, episode) in episodes.enumerated() {
            let code = String(format: "S%02dE%02d", season, episodeIndex + 1)
            let base = folder.appending(path: String(format: "Season %02d", season)).appending(path: "\(show.title) - \(code)")
            let thumb = URL(fileURLWithPath: base.path + "-thumb.jpg")
            try writeIfMissing(thumb) { try backdrop(seed: "\(show.title) \(code)", art: show.art, to: $0) }
            try writeIfMissing(base.appendingPathExtension("nfo")) { url in
                try """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <episodedetails>
                  <title>\(escaped(episode.title))</title>
                  <season>\(season)</season>
                  <episode>\(episodeIndex + 1)</episode>
                  <aired>\(show.year + seasonIndex)-\(String(format: "%02d", 9 + episodeIndex / 4))-\(String(format: "%02d", 1 + episodeIndex * 7 % 28))</aired>
                  <plot>\(escaped(episode.plot))</plot>
                  <lockdata>true</lockdata>
                </episodedetails>
                """.write(to: url, atomically: true, encoding: .utf8)
            }
            encodes.append(Encode(scenes: [Encode.Scene(start: 0, title: nil, still: .file(thumb))], output: base.appendingPathExtension("mkv"),
                                  seconds: show.minutes * 60, resolution: "1920:1080"))
        }
    }
}

// What the pending videos need beyond the library's own pictures, the chapters' stills and their
// chapter lists, is made in a folder of its own for the run.
let pending = encodes.filter { !$0.isCurrent }
let work = fileManager.temporaryDirectory.appending(path: "vinnyfin-showcase-\(UUID().uuidString)")
try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
let drawnStills = try pending.flatMap(\.scenes).reduce(into: [String: URL]()) { stills, scene in
    guard case .drawn(let art, let seed) = scene.still, stills[seed] == nil else { return }
    let url = work.appending(path: "\(stills.count).jpg")
    try backdrop(seed: seed, art: art, to: url)
    stills[seed] = url
}

// Encodes run a few at a time; each is one ffmpeg, holding each still for its scene.
let queue = OperationQueue()
queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
let failures = Mutex<[String]>([])
for encode in pending {
    queue.addOperation {
        let partial = encode.output.deletingPathExtension().appendingPathExtension("partial.mkv")
        var arguments = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y"]
        var filters: [String] = []
        for (index, scene) in encode.scenes.enumerated() {
            let still = switch scene.still {
            case .file(let url): url
            case .drawn(_, let seed): drawnStills[seed]!
            }
            arguments += ["-loop", "1", "-framerate", "1", "-t", "\(encode.end(of: index) - scene.start)", "-i", still.path]
            filters.append("[\(index):v]scale=\(encode.resolution),setsar=1[v\(index)]")
        }
        let count = encode.scenes.count
        filters.append((0..<count).map { "[v\($0)]" }.joined() + "concat=n=\(count):v=1:a=0[video]")
        arguments += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        do {
            if encode.scenes.contains(where: { $0.title != nil }) {
                let chapters = work.appending(path: "\(encode.output.lastPathComponent).txt")
                try encode.chapterMetadata.write(to: chapters, atomically: true, encoding: .utf8)
                arguments += ["-i", chapters.path, "-map_chapters", "\(count + 1)"]
            }
            arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[video]", "-map", "\(count):a",
                          "-t", "\(encode.seconds)"] + Encode.settings + [partial.path]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            if fileManager.fileExists(atPath: encode.output.path) { try fileManager.removeItem(at: encode.output) }
            try fileManager.moveItem(at: partial, to: encode.output)
            try encode.recipe.write(to: encode.recipeFile, atomically: true, encoding: .utf8)
        } catch {
            failures.withLock { $0.append(encode.output.lastPathComponent) }
        }
    }
}
queue.waitUntilAllOperationsAreFinished()
try fileManager.removeItem(at: work)
let failed = failures.withLock { $0 }
if !failed.isEmpty {
    FileHandle.standardError.write(Data("Couldn't encode: \(failed.joined(separator: ", "))\n".utf8))
    exit(1)
}
print("Showcase library ready: \(movies.count) movies, \(shows.count) shows, \(pending.count) videos encoded")
