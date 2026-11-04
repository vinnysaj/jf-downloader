#if os(iOS) || os(visionOS)
import Foundation
import MetricKit
import Observation
import OSLog

/// What the system reports about how the app fared: why it stopped running, off screen and on,
/// a day at a time, and the crashes, hangs and other problems it diagnosed. MetricKit delivers
/// a day's report about once a day, from devices only; the latest `keptReports` and
/// `keptDiagnostics` are kept on disk to show in Settings. Apple Vision Pro sends diagnostics
/// only, not why the app stopped.
@Observable
final class AppDiagnostics {
    static let keptReports = 14
    static let keptDiagnostics = 100
    private static let log = Logger(subsystem: "net.vinnysaj.vinnyfin", category: "diagnostics")

    private(set) var saved = Saved()
    /// A problem keeping the reports, to show until dismissed.
    var problem: String?

    @ObservationIgnored private let manager = MetricManager()
    @ObservationIgnored private let file: URL

    nonisolated struct Saved: Codable, Equatable, Sendable {
        /// Newest first.
        var exits: [ExitReport] = []
        /// Newest first.
        var diagnostics: [Diagnostic] = []
    }

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Diagnostics.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
        } catch {
            problem = "Couldn't read the saved diagnostics: \(error.localizedDescription)"
        }
    }

    /// Takes the system's reports as they come, for the life of the app.
    func run() async {
        await withDiscardingTaskGroup { group in
            #if os(iOS)
            group.addTask {
                for await report in self.manager.metricReports { await self.received(report) }
            }
            #endif
            group.addTask {
                for await report in self.manager.diagnosticReports { await self.received(report) }
            }
        }
    }

    #if os(iOS)
    private func received(_ report: MetricReport) {
        guard !report.intervalEntries.isEmpty else { return }
        var exits = ExitReport(timeRange: report.timeRange)
        for value in report.intervalEntries.fullDayEntry.values {
            switch value {
            case .backgroundTermination(let metric): exits.background = ExitReport.counts(metric)
            case .foregroundTermination(let metric): exits.foreground = ExitReport.counts(metric)
            default: continue
            }
        }
        Self.log.info("Metric report for \(report.timeRange, privacy: .public): \(exits.background.values.reduce(0, +)) background exits")
        saved.exits = ExitReport.keeping(exits, in: saved.exits, limit: Self.keptReports)
        save()
    }
    #endif

    private func received(_ report: DiagnosticReport) {
        let diagnostic = Diagnostic(report)
        Self.log.info("Diagnostic report: \(diagnostic.kind.rawValue, privacy: .public) \(diagnostic.detail ?? "", privacy: .public)")
        saved.diagnostics = Array(([diagnostic] + saved.diagnostics).prefix(Self.keptDiagnostics))
        save()
    }

    private func save() {
        do {
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            problem = "Couldn't save the diagnostics: \(error.localizedDescription)"
        }
    }
}

/// Why the app stopped running, off screen or on, as the system counts it.
nonisolated enum ExitReason: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    // In the order shown: what's worth fixing first, then what's expected.
    case memoryLimit
    case cpuLimit
    case watchdog
    case backgroundTaskTimeout
    case lockedFile
    case badAccess
    case illegalInstruction
    case abnormal
    case memoryPressure
    case normal

    var plainWords: String {
        switch self {
        case .memoryLimit: "Stopped for using too much memory"
        case .cpuLimit: "Stopped for using the processor too much"
        case .watchdog: "Stopped for not responding in time"
        case .backgroundTaskTimeout: "Stopped for running past its background time"
        case .lockedFile: "Stopped for keeping a file locked while suspended"
        case .badAccess: "Crashed reading or writing memory it shouldn't"
        case .illegalInstruction: "Crashed on an invalid instruction"
        case .abnormal: "Crashed or quit on an error"
        case .memoryPressure: "Closed to free up memory for other apps"
        case .normal: "Closed normally, as when swiped away or closed by the system"
        }
    }
}

/// A day's report of why the app stopped running.
nonisolated struct ExitReport: Codable, Equatable, Sendable {
    let timeRange: DateInterval
    /// Off screen, by reason.
    var background: [ExitReason: Int] = [:]
    /// On screen, by reason.
    var foreground: [ExitReason: Int] = [:]

    /// "Stopped for using too much memory: 2", for each reason that happened, worst first.
    static func lines(_ counts: [ExitReason: Int]) -> [String] {
        ExitReason.allCases.compactMap { reason in
            guard let count = counts[reason], count > 0 else { return nil }
            return "\(reason.plainWords): \(count)"
        }
    }

    /// The reports kept with a new one: newest first, one per time range, `limit` at most.
    static func keeping(_ report: ExitReport, in reports: [ExitReport], limit: Int) -> [ExitReport] {
        let others = reports.filter { $0.timeRange != report.timeRange }
        return Array((others + [report]).sorted { $0.timeRange.end > $1.timeRange.end }.prefix(limit))
    }

    #if os(iOS)
    static func counts(_ metric: BackgroundTerminationMetric) -> [ExitReason: Int] {
        [
            .normal: metric.normalTerminationCount,
            .memoryLimit: metric.memoryLimitTerminationCount,
            .cpuLimit: metric.highCPUTerminationCount,
            .memoryPressure: metric.systemPressureTerminationCount,
            .badAccess: metric.badAccessTerminationCount,
            .abnormal: metric.abnormalTerminationCount,
            .illegalInstruction: metric.illegalInstructionTerminationCount,
            .watchdog: metric.watchdogTerminationCount,
            .lockedFile: metric.fileLockTerminationCount,
            .backgroundTaskTimeout: metric.taskTimeoutTerminationCount,
        ]
    }

    static func counts(_ metric: ForegroundTerminationMetric) -> [ExitReason: Int] {
        [
            .normal: metric.normalTerminationCount,
            .memoryLimit: metric.memoryLimitTerminationCount,
            .badAccess: metric.badAccessTerminationCount,
            .abnormal: metric.abnormalTerminationCount,
            .illegalInstruction: metric.illegalInstructionTerminationCount,
            .watchdog: metric.watchdogTerminationCount,
        ]
    }
    #endif
}

/// One problem the system diagnosed: a crash, a hang and the like.
nonisolated struct Diagnostic: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case crash
        case hang
        case cpuException
        case diskWriteException
        case memoryException
        case slowLaunch
        /// A kind this version of the app doesn't know yet.
        case other

        var plainWords: String {
            switch self {
            case .crash: "Crashes"
            case .hang: "Hangs"
            case .cpuException: "Used the processor too much"
            case .diskWriteException: "Wrote too much to storage"
            case .memoryException: "Used too much memory"
            case .slowLaunch: "Slow launches"
            case .other: "Other problems"
            }
        }
    }

    let kind: Kind
    let timeRange: DateInterval
    /// What the system said about it, such as a crash's reason.
    let detail: String?

    init(kind: Kind, timeRange: DateInterval, detail: String? = nil) {
        self.kind = kind
        self.timeRange = timeRange
        self.detail = detail
    }

    /// "Crashes: 2", for each kind that happened, in `Kind` order.
    static func lines(_ diagnostics: [Diagnostic]) -> [String] {
        Kind.allCases.compactMap { kind in
            let count = diagnostics.count { $0.kind == kind }
            return count > 0 ? "\(kind.plainWords): \(count)" : nil
        }
    }

    /// From the earliest diagnostic's start to the latest's end.
    static func timeRange(_ diagnostics: [Diagnostic]) -> DateInterval? {
        guard let start = diagnostics.map(\.timeRange.start).min(), let end = diagnostics.map(\.timeRange.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }
}

nonisolated extension Diagnostic {
    init(_ report: DiagnosticReport) {
        let kind: Kind
        var detail: String?
        switch report.result {
        case .crash(let crash):
            kind = .crash
            detail = crash.exceptionReason?.composedMessage ?? crash.terminationReason?.description ?? crash.terminationCategory?.description
        case .hang(let hang):
            kind = .hang
            detail = hang.hangDuration.formatted(.measurement(width: .abbreviated))
        case .cpuException:
            kind = .cpuException
        case .diskWriteException(let exception):
            kind = .diskWriteException
            detail = exception.totalBytesWritten.formatted(.byteCount(style: .file))
        #if os(iOS)
        case .memoryException:
            kind = .memoryException
        case .appLaunch(let launch):
            kind = .slowLaunch
            detail = launch.launchDuration.formatted(.measurement(width: .abbreviated))
        #endif
        @unknown default:
            kind = .other
        }
        self.init(kind: kind, timeRange: report.timeRange, detail: detail)
    }
}
#endif
