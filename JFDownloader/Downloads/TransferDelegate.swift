import Foundation
import Synchronization

/// Receives the background session's callbacks and turns them into one ordered stream of events.
///
/// The system deletes a finished download's file as soon as `didFinishDownloadingTo` returns,
/// so the file is moved to staging right there; the task's single `.finished` event (sent from
/// `didCompleteWithError`, which always comes after) then carries both the file and the outcome.
nonisolated final class TransferDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    struct Finished: Sendable {
        let taskIdentifier: Int
        let tag: TransferTag?
        let response: ResponseInfo?
        let stagedFile: URL?
        let stagedSize: Int64?
        /// The transfer's error, or the error moving its body to staging.
        let error: (any Error)?
        /// For a whole-file transfer the system may be able to continue.
        let resumeData: Data?
    }

    enum Event: Sendable {
        case progress(taskIdentifier: Int, received: Int64)
        case finished(Finished)
        /// Everything the system had queued for a background launch has been delivered.
        case backgroundEventsDelivered
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let stagingDirectory: URL
    private let staged = Mutex<[Int: Result<URL, any Error>]>([:])

    init(stagingDirectory: URL) {
        self.stagingDirectory = stagingDirectory
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = stagingDirectory.appending(path: UUID().uuidString)
        let result = Result { try FileManager.default.moveItem(at: location, to: destination) }.map { destination }
        staged.withLock { $0[downloadTask.taskIdentifier] = result }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield(.progress(taskIdentifier: downloadTask.taskIdentifier, received: totalBytesWritten))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let stagedResult = staged.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        var stagedFile: URL?
        var stagingError: (any Error)?
        switch stagedResult {
        case .success(let url): stagedFile = url
        case .failure(let failure): stagingError = failure
        case nil: break
        }
        let stagedSize = stagedFile.flatMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        continuation.yield(.finished(Finished(
            taskIdentifier: task.taskIdentifier,
            tag: TransferTag(encoded: task.taskDescription),
            response: (task.response as? HTTPURLResponse).map(ResponseInfo.init),
            stagedFile: stagedFile,
            stagedSize: stagedSize,
            error: error ?? stagingError,
            resumeData: (error as? URLError)?.downloadTaskResumeData
        )))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.backgroundEventsDelivered)
    }
}
