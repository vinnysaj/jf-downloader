import AetherEngine
import SwiftUI

/// Draws the cues showing at the frame on screen: styled text near the bottom (or where the
/// cue asks), and picture subtitles (Blu-ray, DVD, DVB) where they were authored.
struct SubtitleOverlay: View {
    let model: PlayerModel
    /// The picture's size in pixels, for placing picture subtitles; nil fills the view.
    var videoSize: CGSize?
    /// The top of the player's controls in global coordinates while they show. Captions at the
    /// bottom move up above them.
    var controlsTop: CGFloat?
    @Environment(AppSettings.self) private var settings

    var body: some View {
        GeometryReader { geometry in
            let time = model.clock.sourceTime
            let active = model.cues.filter { $0.startTime <= time && time < $0.endTime }
            let videoRect = Self.fittedRect(content: videoSize ?? geometry.size, in: geometry.size)
            let clearAbove = controlsTop.map { $0 - geometry.frame(in: .global).minY }
            ZStack {
                ForEach(active) { cue in
                    switch cue.body {
                    case .image(let image):
                        picture(image, videoRect: videoRect)
                    case .text(let text):
                        caption(Text(text), placement: cue.placement, videoRect: videoRect, clearAbove: clearAbove)
                    case .richText(let runs):
                        caption(Self.styled(runs), placement: cue.placement, videoRect: videoRect, clearAbove: clearAbove)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func caption(_ text: Text, placement: SubtitleTextPlacement?, videoRect: CGRect, clearAbove: CGFloat?) -> some View {
        let size = max(14, videoRect.height * 0.052 * settings.subtitleScale)
        let alignment = placement?.alignment ?? 2
        let vertical: VerticalAlignment = alignment >= 7 ? .top : (alignment >= 4 ? .center : .bottom)
        let margin = videoRect.height * 0.07
        var lift: CGFloat = 0
        if vertical == .bottom, let clearAbove {
            lift = max(0, videoRect.maxY - margin - (clearAbove - 12))
        }
        let horizontal: HorizontalAlignment = [1, 4, 7].contains(alignment) ? .leading : ([3, 6, 9].contains(alignment) ? .trailing : .center)
        return text
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(horizontal == .leading ? .leading : (horizontal == .trailing ? .trailing : .center))
            .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 1)
            .shadow(color: .black.opacity(0.7), radius: 5)
            .padding(.horizontal, videoRect.width * 0.06)
            .padding(.top, margin)
            .padding(.bottom, margin + lift)
            .frame(width: videoRect.width, height: videoRect.height, alignment: Alignment(horizontal: horizontal, vertical: vertical))
            .position(x: videoRect.midX, y: videoRect.midY)
    }

    private func picture(_ image: SubtitleImage, videoRect: CGRect) -> some View {
        let canvas = image.canvasSize.width > 0 ? image.canvasSize : (videoSize ?? videoRect.size)
        let canvasRect = Self.fittedRect(content: canvas, in: videoRect.size).offsetBy(dx: videoRect.minX, dy: videoRect.minY)
        let scale = canvasRect.width / max(1, canvas.width)
        let frame = CGRect(
            x: canvasRect.minX + image.position.minX * scale,
            y: canvasRect.minY + image.position.minY * scale,
            width: image.position.width * scale,
            height: image.position.height * scale
        )
        return Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    /// `content` scaled to fit `container`, centred.
    static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    static func styled(_ runs: [SubtitleTextRun]) -> Text {
        runs.reduce(Text("")) { text, run in
            var piece = Text(run.text)
            if run.isBold { piece = piece.bold() }
            if run.isItalic { piece = piece.italic() }
            if run.isUnderlined { piece = piece.underline() }
            if run.isStruckThrough { piece = piece.strikethrough() }
            if let color = run.color {
                piece = piece.foregroundStyle(Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255))
            }
            return Text("\(text)\(piece)")
        }
    }
}
