import XCTest
@testable import LibrarianKit

/// Catalog: WATCH-01 … WATCH-03 (test-case.md).
final class FolderWatcherTests: XCTestCase {
    // WATCH-01
    func testDetectsNewFile() throws {
        let root = try makeTempDir()
        let expectation = expectation(description: "change detected")
        expectation.assertForOverFulfill = false
        let watcher = FolderWatcher(debounceInterval: 0.2) {
            expectation.fulfill()
        }
        watcher.start(watching: root)
        defer { watcher.stop() }

        // FSEvents needs a beat to arm before the first event.
        Thread.sleep(forTimeInterval: 0.3)
        try Data("new".utf8).write(to: root.appendingPathComponent("new-book.epub"))
        wait(for: [expectation], timeout: 5)
    }

    // WATCH-02
    func testDebounceCoalesces() throws {
        let root = try makeTempDir()
        let recorder = CallRecorder()
        let watcher = FolderWatcher(debounceInterval: 0.4) {
            recorder.record("fire")
        }
        watcher.start(watching: root)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)

        for i in 0..<5 {
            try Data("burst".utf8).write(to: root.appendingPathComponent("b\(i).epub"))
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Wait past the debounce window plus FSEvents latency.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(recorder.count(of: "fire"), 1,
                       "a burst of writes must coalesce into one callback")
    }

    // WATCH-03
    func testStopPreventsCallbacks() throws {
        let root = try makeTempDir()
        let recorder = CallRecorder()
        let watcher = FolderWatcher(debounceInterval: 0.1) {
            recorder.record("fire")
        }
        watcher.start(watching: root)
        Thread.sleep(forTimeInterval: 0.3)
        watcher.stop()
        // FSEvents may flush a stray arming-time event before stop(); only
        // events after stop() matter here.
        let baseline = recorder.count(of: "fire")

        try Data("late".utf8).write(to: root.appendingPathComponent("late.epub"))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(recorder.count(of: "fire"), baseline)
    }
}
