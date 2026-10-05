//
//  DownloadEngine.swift
//  tabmenu
//

import Foundation
import os

/// What a transfer reports back.
///
/// Every value is absolute rather than a delta, so a message that arrives out of order can
/// only ever be stale — it can never walk the progress backwards.
nonisolated enum DownloadEvent: Sendable {
    case started(id: UUID, totalBytes: Int64?, receivedBytes: Int64, isResumable: Bool)
    case progress(id: UUID, receivedBytes: Int64, bytesPerSecond: Double)
    /// A total that was unknown, or only estimated, has firmed up.
    case resized(id: UUID, totalBytes: Int64)
    /// The transfer knows what the file is really called — the media helper only settles on
    /// a name once it has the page's title and the format it ended up with.
    case named(id: UUID, fileName: String)
    case finished(id: UUID, receivedBytes: Int64)
    /// - Parameter isTransient: Whether trying again is worth doing. A dropped connection is;
    ///   a 404 is not. The difference decides whether the queue waits or gives up.
    case failed(id: UUID, reason: String, isTransient: Bool)
}

/// Moves the bytes.
///
/// One connection per download, appended to a `.part` file beside the destination. That is
/// what lets a transfer survive quitting the app: the offset to resume from is the size of
/// that file, not a token the system may have thrown away, so a relaunch continues rather
/// than starting over.
///
/// All state below lives on the session's serial delegate queue. Requests from the queue
/// controller hop onto it before touching anything, which is why nothing here needs a lock:
/// registration always happens before `resume`, and every callback for a task arrives
/// afterwards, in order, on that same queue.
nonisolated final class DownloadEngine: NSObject, @unchecked Sendable {
    /// How often progress is reported. Four times a second is smooth to the eye and keeps
    /// the queue from re-rendering on every packet.
    private static let progressInterval: TimeInterval = 0.25
    /// Weight of a new speed sample. Raw samples swing wildly on a real connection.
    private static let speedSmoothing = 0.35

    private let logger = Logger(subsystem: "com.tabmenu", category: "Downloads")
    private let onEvent: @Sendable (DownloadEvent) -> Void
    private let queue: OperationQueue
    /// Assigned once, right after `super.init`, because the session takes this object as its
    /// delegate and a stored property cannot reference `self` any earlier.
    private var session: URLSession!

    /// One in-flight transfer. Touched only on the delegate queue.
    private final class Transfer {
        let id: UUID
        let task: URLSessionDataTask
        let partURL: URL
        var handle: FileHandle?
        /// Bytes already on disk when the request went out.
        var startOffset: Int64
        var received: Int64
        var isPaused = false
        var lastSampleTime: TimeInterval
        var lastSampleBytes: Int64
        var lastReportTime: TimeInterval
        var speed: Double = 0

        init(id: UUID, task: URLSessionDataTask, partURL: URL, startOffset: Int64, now: TimeInterval) {
            self.id = id
            self.task = task
            self.partURL = partURL
            self.startOffset = startOffset
            self.received = startOffset
            self.lastSampleTime = now
            self.lastSampleBytes = startOffset
            self.lastReportTime = now
        }
    }

    private var transfers: [Int: Transfer] = [:]

    init(onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
        self.onEvent = onEvent
        self.queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.tabmenu.downloads"
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        // No ceiling on the transfer itself: a large file on a slow line is not a failure.
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - Control

    /// Starts or resumes a transfer. `offset` is the size of the existing `.part` file; the
    /// server is asked to continue from there and the response says whether it obliged.
    /// - Parameter headers: What the browser would have sent — cookies above all. A signed
    ///   link or a members-only file is refused without them, and this is the difference
    ///   between a download manager that works on real sites and one that works on examples.
    func start(id: UUID, url: URL, partURL: URL, offset: Int64, headers: [String: String]? = nil) {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Set last, so a stale Range from the browser's own attempt cannot override ours.
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        queue.addOperation { [weak self] in
            guard let self else { return }
            let transfer = Transfer(
                id: id,
                task: task,
                partURL: partURL,
                startOffset: offset,
                now: ProcessInfo.processInfo.systemUptime
            )
            transfers[task.taskIdentifier] = transfer
            task.resume()
        }
    }

    /// Stops a transfer without discarding what is on disk. No event follows: the caller has
    /// already recorded the new state, and a cancellation is not a failure.
    func pause(id: UUID) {
        queue.addOperation { [weak self] in
            guard let self, let entry = transfer(for: id) else { return }
            entry.isPaused = true
            entry.task.cancel()
        }
    }

    private func transfer(for id: UUID) -> Transfer? {
        transfers.values.first { $0.id == id }
    }

    // MARK: - Files

    /// Opens the part file for appending, creating it when this is a fresh start.
    private func openHandle(_ transfer: Transfer, truncating: Bool) -> FileHandle? {
        let manager = FileManager.default
        let path = transfer.partURL.path

        if truncating || !manager.fileExists(atPath: path) {
            _ = manager.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: transfer.partURL) else {
            logger.error("cannot write \(transfer.partURL.lastPathComponent, privacy: .public)")
            return nil
        }
        if truncating {
            try? handle.truncate(atOffset: 0)
        } else {
            _ = try? handle.seekToEnd()
        }
        return handle
    }

    private func finish(_ transfer: Transfer, event: DownloadEvent?) {
        try? transfer.handle?.close()
        transfer.handle = nil
        transfers[transfer.task.taskIdentifier] = nil
        if let event { onEvent(event) }
    }
}

// MARK: - URLSession delegate

nonisolated extension DownloadEngine: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer = transfers[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(transfer, event: .failed(
                id: transfer.id,
                reason: String(localized: "Not an HTTP response", comment: "Download failure"),
                isTransient: false
            ))
            return
        }

        // 416 means the range asked for is past the end of the file, which is what a server
        // says when the part file already holds everything there is.
        if http.statusCode == 416, transfer.startOffset > 0 {
            completionHandler(.cancel)
            finish(transfer, event: .finished(id: transfer.id, receivedBytes: transfer.startOffset))
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(transfer, event: .failed(
                id: transfer.id,
                reason: Self.message(for: http.statusCode),
                // A server that is rate limiting or having a bad minute will serve this later.
                isTransient: http.statusCode == 429 || (500..<600).contains(http.statusCode)
            ))
            return
        }

        // 206 means the server honoured the range and is continuing. A plain 200 to a ranged
        // request means it ignored it and is sending the whole file again, so what is already
        // on disk has to go or the file ends up with the first chunk twice.
        let isContinuing = http.statusCode == 206 && transfer.startOffset > 0
        if !isContinuing {
            transfer.startOffset = 0
            transfer.received = 0
            transfer.lastSampleBytes = 0
        }

        transfer.handle = openHandle(transfer, truncating: !isContinuing)
        guard transfer.handle != nil else {
            completionHandler(.cancel)
            finish(transfer, event: .failed(
                id: transfer.id,
                reason: String(localized: "Cannot write to the download folder", comment: "Download failure"),
                isTransient: false
            ))
            return
        }

        onEvent(.started(
            id: transfer.id,
            totalBytes: Self.totalBytes(from: http, offset: transfer.startOffset),
            receivedBytes: transfer.received,
            isResumable: http.statusCode == 206
                || (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false)
        ))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers[dataTask.taskIdentifier], let handle = transfer.handle else { return }

        do {
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(transfer, event: .failed(
                id: transfer.id,
                reason: error.localizedDescription,
                isTransient: false
            ))
            return
        }

        transfer.received += Int64(data.count)

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - transfer.lastSampleTime
        guard elapsed >= Self.progressInterval else { return }

        let sample = Double(transfer.received - transfer.lastSampleBytes) / elapsed
        transfer.speed = transfer.speed == 0
            ? sample
            : transfer.speed + (sample - transfer.speed) * Self.speedSmoothing
        transfer.lastSampleTime = now
        transfer.lastSampleBytes = transfer.received

        onEvent(.progress(
            id: transfer.id,
            receivedBytes: transfer.received,
            bytesPerSecond: max(0, transfer.speed)
        ))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers[task.taskIdentifier] else { return }

        // A paused transfer keeps its part file and says nothing: the queue recorded the
        // pause before asking for it, and a cancellation is not a failure to report.
        if transfer.isPaused {
            finish(transfer, event: nil)
            return
        }

        guard let error else {
            finish(transfer, event: .finished(id: transfer.id, receivedBytes: transfer.received))
            return
        }
        let failure = error as NSError
        if failure.code == NSURLErrorCancelled {
            finish(transfer, event: nil)
            return
        }
        finish(transfer, event: .failed(
            id: transfer.id,
            reason: error.localizedDescription,
            isTransient: Self.isTransient(failure)
        ))
    }

    /// Whether a failure is the network having a moment rather than an answer.
    ///
    /// This is the difference between a download manager and a downloader: a dropped Wi-Fi, a
    /// sleeping Mac or a server that hung up mid-transfer are all things that resolve themselves,
    /// and a queue that gives up on them makes the user the retry mechanism.
    static func isTransient(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorResourceUnavailable,
            NSURLErrorBadServerResponse,
            NSURLErrorZeroByteResource,
            NSURLErrorCannotLoadFromNetwork,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed
        ].contains(error.code)
    }

    // MARK: - Helpers

    /// The size of the whole file, which for a partial response is the total in
    /// `Content-Range` rather than the length of the chunk being sent.
    private static func totalBytes(from response: HTTPURLResponse, offset: Int64) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.components(separatedBy: "/").last,
           let value = Int64(total.trimmingCharacters(in: .whitespaces)) {
            return value
        }
        guard response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength + offset
    }

    /// Status codes users actually hit, in words they can act on.
    private static func message(for statusCode: Int) -> String {
        switch statusCode {
        case 401, 403:
            String(localized: "The server refused the download", comment: "Download failure")
        case 404, 410:
            String(localized: "The link no longer exists", comment: "Download failure")
        case 429:
            String(localized: "The server is rate limiting — try again later", comment: "Download failure")
        case 500..<600:
            String(localized: "The server had a problem", comment: "Download failure")
        default:
            String(localized: "The server answered \(statusCode)", comment: "Download failure")
        }
    }
}
