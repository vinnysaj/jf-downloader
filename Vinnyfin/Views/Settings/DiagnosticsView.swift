#if os(iOS) || os(visionOS)
import SwiftUI

/// What the system reported about why vinnyfin stopped running and what went wrong, for
/// finding out what ends downloads in the background.
struct DiagnosticsView: View {
    @Environment(AppDiagnostics.self) private var diagnostics

    var body: some View {
        let saved = diagnostics.saved
        List {
            if let problem = diagnostics.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Dismiss") { diagnostics.problem = nil }
                }
            }
            ForEach(saved.exits, id: \.timeRange) { report in
                Section {
                    let background = ExitReport.lines(report.background)
                    let foreground = ExitReport.lines(report.foreground)
                    if background.isEmpty, foreground.isEmpty {
                        Text("vinnyfin didn't stop running").foregroundStyle(.secondary)
                    }
                    exitLines(background, heading: "In the Background")
                    exitLines(foreground, heading: "On Screen")
                } header: {
                    Text(report.timeRange.start...report.timeRange.end)
                }
            }
            if !saved.diagnostics.isEmpty {
                Section {
                    ForEach(Diagnostic.lines(saved.diagnostics), id: \.self) { Text($0) }
                    if let crash = saved.diagnostics.first(where: { $0.kind == .crash }), let detail = crash.detail {
                        LabeledContent("Last Crash", value: detail)
                    }
                } header: {
                    Text("Problems Reported")
                } footer: {
                    if let range = Diagnostic.timeRange(saved.diagnostics) { Text(range.start...range.end) }
                }
            }
        }
        .overlay {
            if saved.exits.isEmpty, saved.diagnostics.isEmpty {
                ContentUnavailableView(
                    "No Reports Yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("The system sends a report about once a day, for the day before, on a device rather than the Simulator.")
                )
            }
        }
        .navigationTitle("Diagnostics")
    }

    @ViewBuilder private func exitLines(_ lines: [String], heading: String) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.subheadline.weight(.semibold))
                ForEach(lines, id: \.self) { Text($0).font(.subheadline) }
            }
            .padding(.vertical, 2)
        }
    }
}

#endif
