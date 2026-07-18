import Foundation
import BookShelfKit

func folderWatcherTests(_ runner: TestRunner) async {
    await runner.run("folder watcher: debounced change fires once, stop silences") {
        try await withTempDirectory { dir in
            final class Counter: @unchecked Sendable {
                private let lock = NSLock()
                private var value = 0
                func increment() { lock.lock(); value += 1; lock.unlock() }
                var count: Int { lock.lock(); defer { lock.unlock() }; return value }
            }
            let counter = Counter()
            let watcher = FolderWatcher(debounceInterval: 0.5, latency: 0.1) {
                counter.increment()
            }
            watcher.start(watching: dir)
            expect(watcher.isWatching, "stream should be running")

            // A burst of writes must collapse into a single callback.
            for i in 0..<5 {
                try "book \(i)".data(using: .utf8)!
                    .write(to: dir.appendingPathComponent("book\(i).epub"))
            }

            // FSEvents latency + debounce; poll up to 10s to stay robust.
            var waited = 0.0
            while counter.count == 0 && waited < 10 {
                try await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            expect(counter.count >= 1, "watcher never fired within 10s")

            // Let any trailing debounce settle, then confirm the burst
            // produced far fewer callbacks than writes.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let afterBurst = counter.count
            expect(afterBurst <= 2, "burst of 5 writes fired \(afterBurst) callbacks")

            // After stop(), further changes are ignored.
            watcher.stop()
            expect(!watcher.isWatching)
            try "late".data(using: .utf8)!
                .write(to: dir.appendingPathComponent("late.epub"))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            expectEqual(counter.count, afterBurst, "no callbacks after stop")
        }
    }
}
