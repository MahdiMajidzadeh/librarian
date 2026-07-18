import Foundation
import CoreServices

/// Recursive FSEvents watcher for the library root (FR-1.6, P1).
///
/// Fires `onChange` once disk activity has settled for `debounceInterval`
/// seconds, so a batch copy of 200 books triggers one rescan, not 200.
/// App-initiated renames are safe to re-observe: the database is updated
/// atomically with each move, so the follow-up incremental rescan sees
/// every file as unchanged.
public final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bookshelf.folder-watcher")
    private let debounceInterval: TimeInterval
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void

    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?

    public init(
        debounceInterval: TimeInterval = 2.0,
        latency: TimeInterval = 1.0,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public var isWatching: Bool {
        queue.sync { stream != nil }
    }

    public func start(watching url: URL) {
        queue.sync {
            stopLocked()

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                    .scheduleChange()
            }
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [url.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            ) else { return }

            FSEventStreamSetDispatchQueue(stream, queue)
            if FSEventStreamStart(stream) {
                self.stream = stream
            } else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    /// Must run on `queue`.
    private func stopLocked() {
        debounceWork?.cancel()
        debounceWork = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Runs on `queue` (FSEvents delivery queue).
    private func scheduleChange() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
