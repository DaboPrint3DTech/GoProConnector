import Foundation

/// Scarica file grandi su disco con notifiche di avanzamento.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ written: Int64, _ expected: Int64) -> Void

    private struct Handler {
        let destination: URL
        let progress: Progress
        let continuation: CheckedContinuation<Void, Error>
        var moveError: Error?
    }

    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30      // inattività massima
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Scarica `url` in `destination` (sovrascrive se esiste).
    func download(_ url: URL, to destination: URL, progress: @escaping Progress) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let t = session.downloadTask(with: url)
                lock.withLock {
                    handlers[t.taskIdentifier] = Handler(destination: destination, progress: progress, continuation: cont)
                }
                box.set(t)
                t.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ t: URLSessionTask) {
            let shouldCancel = lock.withLock { task = t; return cancelled }
            if shouldCancel { t.cancel() }
        }

        func cancel() {
            let t = lock.withLock { cancelled = true; return task }
            t?.cancel()
        }
    }

    func cancelAll() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let h = lock.withLock { handlers[downloadTask.taskIdentifier] }
        h?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        guard let h = lock.withLock({ handlers[id] }) else { return }
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw GoProError.badResponse(http.statusCode)
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: h.destination.path) { try fm.removeItem(at: h.destination) }
            try fm.moveItem(at: location, to: h.destination)
        } catch {
            lock.withLock { handlers[id]?.moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let h = lock.withLock({ handlers.removeValue(forKey: id) }) else { return }
        if let error = error ?? h.moveError {
            if (error as? URLError)?.code == .cancelled {
                h.continuation.resume(throwing: CancellationError())
            } else {
                h.continuation.resume(throwing: error)
            }
        } else {
            h.continuation.resume()
        }
    }
}
