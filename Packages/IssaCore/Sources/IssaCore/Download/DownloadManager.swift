import Foundation
import Observation

/// How much room is left, asked the way each platform allows.
///
/// `volumeAvailableCapacityForImportantUsage` — which reports space the system
/// would free by purging caches, and is the honest number for a download the
/// user asked for — does not exist on tvOS, where the plain capacity is all
/// there is.
public enum DiskSpace {
    public static func available(
        at url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
    ) -> Int64? {
        #if os(tvOS)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return nil }
        return Int64(capacity)
        #else
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
        #endif
    }
}

/// Downloads books, and keeps downloading them when the app is not running.
///
/// The previous implementation buffered a whole file through `Data` — a 79 MB
/// readaloud edition entirely resident in memory, with no progress, no cancel
/// and no way to start one deliberately. This streams to disk through a
/// background `URLSession`, so a download survives the app being suspended or
/// killed, and a five-hour audiobook costs no more memory than a page of text.
@Observable
@MainActor
public final class DownloadManager: NSObject {
    public enum State: Equatable, Sendable {
        case queued
        case downloading(fractionCompleted: Double, bytesWritten: Int64, totalBytes: Int64)
        case paused(fractionCompleted: Double)
        case finished
        case failed(String)

        public var fraction: Double {
            switch self {
            case .queued: 0
            case let .downloading(fraction, _, _): fraction
            case let .paused(fraction): fraction
            case .finished: 1
            case .failed: 0
            }
        }

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        /// True when the total size is unknown, so a bar should be
        /// indeterminate rather than sitting at zero — which is indisputably
        /// what a stalled download also looks like.
        public var isIndeterminate: Bool {
            if case let .downloading(_, _, total) = self { return total <= 0 }
            return false
        }

        public var isActive: Bool {
            switch self {
            case .queued, .downloading: true
            default: false
            }
        }
    }

    /// Identifies one download: a book in one edition.
    public struct Job: Hashable, Sendable {
        public let bookUUID: String
        public let format: BookContentService.Format

        public init(bookUUID: String, format: BookContentService.Format) {
            self.bookUUID = bookUUID
            self.format = format
        }
    }

    public private(set) var states: [Job: State] = [:]
    /// Only download over Wi-Fi. Honoured by the session, not merely by us.
    /// Set per request rather than on the session: a background session's
    /// configuration is copied at creation, so toggling it later would do
    /// nothing until the next launch.
    public var wifiOnly = false {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Self.wifiOnlyKey) }
    }

    public var onFinished: ((Job) -> Void)?

    private static let wifiOnlyKey = "issa.downloads.wifiOnly"
    private let baseURL: URL
    private let tokens: any TokenProviding
    /// Nonisolated so the delegate can resolve a destination on its own queue:
    /// the temporary file is deleted the instant the callback returns, so the
    /// move cannot wait for a hop to the main actor.
    private nonisolated let destinationFor: @Sendable (Job) -> URL
    private var session: URLSession!
    private var tasks: [Job: URLSessionDownloadTask] = [:]
    private var resumeData: [Job: Data] = [:]
    /// Jobs the app itself paused.
    ///
    /// A pause cancels the task, and a cancellation is otherwise
    /// indistinguishable from the system killing a transfer — so without this
    /// the delegate had to ignore every cancellation, which left a killed
    /// download showing "downloading" forever with every button dead.
    private var pausing: Set<Job> = []
    /// Set when the session has been torn down, so late delegate callbacks from
    /// a superseded session cannot write state the app is no longer showing.
    private var isShutDown = false

    public init(
        baseURL: URL,
        tokens: any TokenProviding,
        identifier: String = "com.benjaminissa.issareader.downloads",
        destinationFor: @escaping @Sendable (Job) -> URL,
    ) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.destinationFor = destinationFor
        super.init()

        wifiOnly = UserDefaults.standard.bool(forKey: Self.wifiOnlyKey)

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // A book is worth finishing even if the reader locks the phone.
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func state(for job: Job) -> State? { states[job] }

    /// Everything not yet finished, for the Downloads screen.
    public var pending: [(job: Job, state: State)] {
        states.filter { $0.value != .finished }
            .map { (job: $0.key, state: $0.value) }
            .sorted { $0.job.bookUUID < $1.job.bookUUID }
    }

    /// Forgets a finished or failed download so its row leaves the screen.
    public func clear(_ job: Job) { states[job] = nil }

    /// Starts, or resumes, a download.
    public func start(_ job: Job, expectedBytes: Int64? = nil) async {
        guard states[job]?.isActive != true else { return }

        if let expectedBytes, !Self.hasRoom(for: expectedBytes) {
            states[job] = .failed("Not enough space on this device.")
            return
        }

        // Claim the job before the first await. Two callers arriving together —
        // the reader re-entering after a layout pass is the ordinary case —
        // would otherwise both pass the guard above while the token was being
        // fetched, and start two transfers for one file.
        states[job] = .queued

        var request = URLRequest(url: baseURL.appending(path: Endpoint.files(job.bookUUID)))
        request.url?.append(queryItems: [URLQueryItem(name: "format", value: job.format.rawValue)])
        if let token = await tokens.currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.allowsCellularAccess = !wifiOnly

        // Resuming from a partial transfer beats starting a 79 MB file again.
        let task = if let data = resumeData.removeValue(forKey: job) {
            session.downloadTask(withResumeData: data)
        } else {
            session.downloadTask(with: request)
        }
        task.taskDescription = Self.encode(job)
        tasks[job] = task
        task.resume()
    }

    /// A sentence worth showing someone.
    ///
    /// `localizedDescription` for `NSURLErrorUnknown` is literally "unknown
    /// error", which now that the reason is drawn beneath the button is a
    /// dead end printed on screen rather than a hint.
    nonisolated static func readableReason(for error: any Error) -> String {
        let error = error as NSError
        let described = error.localizedDescription
        guard error.code == NSURLErrorUnknown || described.isEmpty else { return described }
        return "The download could not start. Tap to try again."
    }

    public func pause(_ job: Job) {
        guard let task = tasks[job] else {
            // A job is `.queued` from the moment it is asked for until its
            // first byte arrives — which for a request that 404s is never. With
            // no task handle to cancel this returned silently, so the button
            // offering to pause a waiting download did nothing at all.
            if states[job]?.isActive == true { states[job] = .paused(fractionCompleted: 0) }
            return
        }
        pausing.insert(job)
        let fraction = states[job]?.fraction ?? 0
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.resumeData[job] = data }
                self.states[job] = .paused(fractionCompleted: fraction)
                self.tasks[job] = nil
            }
        }
    }

    public func cancel(_ job: Job) {
        pausing.insert(job)
        tasks[job]?.cancel()
        tasks[job] = nil
        resumeData[job] = nil
        states[job] = nil
    }

    /// Ends this manager's session for good.
    ///
    /// A background session owns its identifier for the whole process, so a
    /// second one built on the same identifier makes the daemon hand the
    /// transfers to one owner and kill the other's — which is what cancelled
    /// downloads mid-flight. Nothing invalidated the old session, and the
    /// URLSession/delegate pair retains itself, so old managers leaked and went
    /// on mutating state nothing was reading.
    public func shutDown() async {
        isShutDown = true
        session.finishTasksAndInvalidate()
    }

    /// Reattaches to whatever the system carried on with while the app was away.
    public func reattach() async {
        let running = await session.tasks.2
        for task in running {
            guard let description = task.taskDescription, let job = Self.decode(description) else { continue }
            tasks[job] = task
            states[job] = .downloading(fractionCompleted: task.progress.fractionCompleted,
                                       bytesWritten: task.countOfBytesReceived,
                                       totalBytes: task.countOfBytesExpectedToReceive)
        }
    }

    /// Refuses a download that plainly will not fit, with a real number rather
    /// than a failure part-way through.
    nonisolated static func hasRoom(for bytes: Int64) -> Bool {
        guard let available = DiskSpace.available() else { return true }
        // Leave headroom: filling the disk exactly is its own failure.
        return available > bytes + 200_000_000
    }

    nonisolated static func encode(_ job: Job) -> String { "\(job.bookUUID)|\(job.format.rawValue)" }

    /// Nonisolated because the URLSession delegate callbacks arrive on the
    /// session's own queue and need to identify the job before hopping.
    nonisolated static func decode(_ description: String) -> Job? {
        let parts = description.split(separator: "|")
        guard parts.count == 2, let format = BookContentService.Format(rawValue: String(parts[1]))
        else { return nil }
        return Job(bookUUID: String(parts[0]), format: format)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
    ) {
        guard let description = downloadTask.taskDescription,
              let job = Self.decode(description) else { return }
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor [weak self] in
            guard let self, !self.isShutDown else { return }
            self.states[job] = DownloadManager.State.downloading(
                fractionCompleted: fraction,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite,
            )
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL,
    ) {
        guard let description = downloadTask.taskDescription,
              let job = Self.decode(description) else { return }

        // The temporary file is deleted the moment this returns, so it has to be
        // moved here and now, synchronously, before hopping to the actor.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var moveError: String?
        if (200 ..< 300).contains(status) {
            let destination = destinationFor(job)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                IssaLog.failure("move downloaded file", error,
                                ["to": destination.lastPathComponent])
                moveError = error.localizedDescription
            }
        } else {
            moveError = "The server returned \(status)."
        }

        let failure = moveError
        Task { @MainActor [weak self] in
            guard let self, !self.isShutDown else { return }
            self.tasks[job] = nil
            self.pausing.remove(job)
            if let failure {
                self.states[job] = .failed(failure)
            } else {
                self.states[job] = .finished
                self.onFinished?(job)
            }
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?,
    ) {
        guard let error, let description = task.taskDescription,
              let job = Self.decode(description) else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = Self.readableReason(for: error)
        let cancelled = (error as NSError).code == NSURLErrorCancelled

        Task { @MainActor [weak self] in
            guard let self, !self.isShutDown else { return }
            self.tasks[job] = nil
            if let resume { self.resumeData[job] = resume }
            if cancelled {
                // Only a cancellation we asked for is not a failure. Anything
                // else — the system reclaiming the transfer, a second session
                // taking the identifier — has to be reported, or the row sits
                // at "downloading" forever and every control on it is dead.
                if self.pausing.remove(job) != nil { return }
                self.states[job] = .failed("The download was interrupted. Tap to try again.")
                return
            }
            self.states[job] = .failed(message)
        }
    }
}
