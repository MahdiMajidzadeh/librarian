import Foundation

/// Minimal test harness for Command Line Tools environments where XCTest is
/// unavailable. Tests register with `TestRunner.run` and report via the
/// `expect*` helpers; the process exits non-zero if any test fails.
final class TestRunner {
    static let shared = TestRunner()

    private var passed = 0
    private var failures: [(test: String, message: String)] = []
    private var currentTest = ""
    private var currentTestFailed = false

    func run(_ name: String, _ body: () async throws -> Void) async {
        currentTest = name
        currentTestFailed = false
        do {
            try await body()
        } catch {
            record("threw \(error)")
        }
        if currentTestFailed {
            print("[FAIL] \(name)")
        } else {
            passed += 1
            print("[ ok ] \(name)")
        }
    }

    func record(_ message: String, file: StaticString = #file, line: UInt = #line) {
        currentTestFailed = true
        let fileName = ("\(file)" as NSString).lastPathComponent
        failures.append((currentTest, "\(fileName):\(line): \(message)"))
    }

    func finish() -> Never {
        print("")
        if failures.isEmpty {
            print("All \(passed) tests passed.")
            exit(0)
        }
        print("\(passed) passed, \(failures.count) failure(s):")
        for failure in failures {
            print("  \(failure.test) — \(failure.message)")
        }
        exit(1)
    }
}

func expect(_ condition: Bool, _ message: String = "expected condition to hold",
            file: StaticString = #file, line: UInt = #line) {
    if !condition {
        TestRunner.shared.record(message, file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               _ message: String = "",
                               file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        let detail = message.isEmpty ? "" : " — \(message)"
        TestRunner.shared.record("expected \(expected), got \(actual)\(detail)", file: file, line: line)
    }
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil",
                  file: StaticString = #file, line: UInt = #line) {
    if let value {
        TestRunner.shared.record("\(message), got \(value)", file: file, line: line)
    }
}

func expectNotNil<T>(_ value: T?, _ message: String = "expected non-nil value",
                     file: StaticString = #file, line: UInt = #line) -> T? {
    if value == nil {
        TestRunner.shared.record(message, file: file, line: line)
    }
    return value
}

func expectThrows(_ message: String = "expected an error to be thrown",
                  file: StaticString = #file, line: UInt = #line,
                  _ body: () throws -> Void) {
    do {
        try body()
        TestRunner.shared.record(message, file: file, line: line)
    } catch {
        // expected
    }
}

/// Creates a unique temporary directory for a test and removes it afterwards.
func withTempDirectory(_ body: (URL) async throws -> Void) async rethrows {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bookshelf-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
