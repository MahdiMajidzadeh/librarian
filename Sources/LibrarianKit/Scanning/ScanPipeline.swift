import Foundation

/// Runs scans on a background queue, one at a time (FR-1.3). Progress and
/// completion are delivered to the caller's callbacks; requests arriving
/// while a scan runs are coalesced into one follow-up scan (used by the
/// folder watcher, FR-1.6).
public final class ScanPipeline: @unchecked Sendable {
    private let scanner: LibraryScanner
    private let queue = DispatchQueue(label: "librarian.scan", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var pendingRescan = false

    public init(scanner: LibraryScanner) {
        self.scanner = scanner
    }

    public var isScanning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Requests a scan. Returns false when a scan is already running (a
    /// follow-up scan is queued instead, so no change is lost).
    @discardableResult
    public func requestScan(
        root: URL,
        progress: @escaping @Sendable (ScanProgress) -> Void,
        completion: @escaping @Sendable (Result<ScanSummary, Error>) -> Void
    ) -> Bool {
        lock.lock()
        if running {
            pendingRescan = true
            lock.unlock()
            return false
        }
        running = true
        lock.unlock()

        queue.async { [self] in
            let result = Result { try scanner.scan(root: root, progress: progress) }

            lock.lock()
            running = false
            let followUp = pendingRescan
            pendingRescan = false
            lock.unlock()

            completion(result)
            if followUp {
                requestScan(root: root, progress: progress, completion: completion)
            }
        }
        return true
    }

    /// Synchronous scan for callers already off the main thread (tests, seed).
    public func scanNow(
        root: URL,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) throws -> ScanSummary {
        try scanner.scan(root: root, progress: progress)
    }
}
