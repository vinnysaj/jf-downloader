import SwiftUI

/// The player's choice panels. While one is open the controls stay up.
enum PlayerPanel: Identifiable {
    case audio, subtitles, speed

    var id: Self { self }

    var title: String {
        switch self {
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        case .speed: "Speed"
        }
    }

    var symbol: String {
        switch self {
        case .audio: "speaker.wave.2"
        case .subtitles: "captions.bubble"
        case .speed: "gauge.with.dots.needle.67percent"
        }
    }
}

/// A list of audio tracks, subtitle tracks or speeds, with the current one checked.
struct TrackPanel: View {
    let model: PlayerModel
    let panel: PlayerPanel
    let onClose: () -> Void

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let isSelected: Bool
        let choose: () -> Void
    }

    private static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    #if os(tvOS)
    /// The remote starts on the current choice, inside the panel.
    @FocusState private var focusedRow: String?
    #endif

    private var rows: [Row] {
        switch panel {
        case .audio:
            return model.audioOptions.map { option in
                Row(id: "audio.\(option.id)", title: option.title, detail: option.detail,
                    isSelected: model.selectedAudio == option.id) { model.chooseAudio(option.id) }
            }
        case .subtitles:
            let off = Row(id: "subtitle.off", title: "Off", detail: nil, isSelected: model.selectedSubtitle == nil) {
                model.chooseSubtitle(nil)
            }
            return [off] + model.subtitleOptions.map { option in
                Row(id: "subtitle.\(option.id)", title: option.title, detail: option.detail,
                    isSelected: model.selectedSubtitle == option.id) { model.chooseSubtitle(option.id) }
            }
        case .speed:
            return Self.rates.map { rate in
                Row(id: "speed.\(rate)", title: rate == 1 ? "Normal" : "\(rate.formatted())×", detail: nil,
                    isSelected: model.rate == rate) { model.setRate(rate) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(panel.title, systemImage: panel.symbol).font(.headline)
                Spacer()
                #if !os(tvOS)
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.platformGlass)
                    .buttonBorderShape(.circle)
                #endif
            }
            .padding([.horizontal, .top])
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        Button {
                            row.choose()
                            onClose()
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .opacity(row.isSelected ? 1 : 0)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                    if let detail = row.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        // Plain lifts the whole row when the remote is on it.
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .focused($focusedRow, equals: row.id)
                        #endif
                        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
                        .accessibilityIdentifier("panel.\(row.id)")
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: Self.width)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .platformGlass(in: .rect(cornerRadius: 24))
        #if os(tvOS)
        .focusSection()
        .onAppear { focusedRow = rows.first(where: \.isSelected)?.id ?? rows.first?.id }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.panel")
    }

    private static var width: CGFloat {
        #if os(tvOS)
        560
        #else
        320
        #endif
    }
}
