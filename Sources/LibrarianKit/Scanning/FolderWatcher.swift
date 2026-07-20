import Foundation
import CoreServices

/// Watches the library folder with FSEvents and fires a debounced callback
/// when book files change (FR-1.6). The callback typically triggers an
/// incremental rescan through `ScanPipeline`.
public final class FolderWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let callbackQueue = DispatchQueue(label: "librarian.watcher")
    private let onChange: @Sendable () -> Void

    public init(debounceInterval: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start(watching url: URL) {
        lock.lock(); defer { lock.unlock() }
        stopLocked()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scheduleDebounced()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval / 2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }

        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func scheduleDebounced() {
        lock.lock(); defer { lock.unlock() }
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        debounceWorkItem = work
        callbackQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
