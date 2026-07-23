# 02 — Development

## Toolchain

- **Xcode 26.6 / Swift 6.3** (verified on this machine). Everything goes
  through SwiftPM: `swift build`, `swift test`, `swift run`. There is **no
  `.xcodeproj`** and no asset catalog — the app icon is generated from
  `icon.png` at packaging time.
- `Package.swift` uses tools-version 6.0 with **Swift 5 language mode** on all
  targets (strict-concurrency friction isn't worth it here yet).
- Dependencies: **GRDB 7.x** (SQLite), **ZIPFoundation 0.9.x** (epub zip).
  PDFKit/CoreGraphics/ImageIO/FSEvents are system frameworks.
- The app is **unsandboxed and unsigned** (`Scripts/make-app.sh` output).
  `FolderAccess` still creates security-scoped bookmarks when possible and
  degrades gracefully — the code must keep working in both worlds (NFR-5).

## Commands

```bash
swift build                          # debug build (all targets)
swift test                           # full XCTest suite (133 tests)
swift run librarian-seed <dir>       # generate a demo ebook library
Scripts/make-app.sh                  # release build → Librarian.app (with icon)
open Librarian.app
.build/debug/Librarian & sleep 3; kill -0 $!   # smoke-check UI launch
```

## Targets & layout

| Target | Path | Role |
|---|---|---|
| **LibrarianKit** (library) | `Sources/LibrarianKit/` | All logic: Database, Scanning, Grouping, Metadata, Lookup, Rename, Export. **Zero AppKit/SwiftUI** — everything here is headless-testable. |
| **Librarian** (executable) | `Sources/Librarian/` | SwiftUI shell: `LibrarianApp`, `AppModel` (@MainActor state + AppKit panels), `Views/`. |
| **LibrarianFixtures** (library) | `Sources/LibrarianFixtures/` | Programmatic epub/pdf/mobi builders + demo-library seeder. Shared by tests and librarian-seed. Never imported by the app. |
| **librarian-seed** (executable) | `Sources/LibrarianSeed/` | CLI wrapper around `FixtureFactory.seedDemoLibrary`. |
| **LibrarianKitTests** (test) | `Tests/LibrarianKitTests/` | XCTest suite, 1:1 with [test-case.md](../test-case.md). |

**Boundary rule:** if it can be tested without a window, it belongs in
LibrarianKit. The app target only orchestrates and renders.

## Test-case catalog

[`test-case.md`](../test-case.md) at the repo root is the **source of truth**
for the suite. Every XCTest method maps to a catalog ID (DB-xx, SCAN-xx,
GRP-xx, EPUB/PDF/MOBI-xx, META-xx, LOOK-xx, REN-xx, EXP-xx, WATCH-xx,
E2E-xx). If the catalog changes, rewrite the tests to match; if test code
changes, update the catalog in the same commit.

## Conventions & gotchas

- FR/NFR numbers in comments refer to [requirements.md](../requirements.md).
- GRDB's `read`/`write` have async overloads that win inside `async`
  functions — write `try await database.writer.read { … }` there.
- Don't use `Dictionary[key, default: expensive()]` when the default closure
  touches the same dictionary — exclusivity crash (see `RenamePlanner`).
- Lookup tests use `StubProvider` — the suite must never touch the network.
- Test temp dirs come from `makeTempDir()` (TestSupport), which canonicalizes
  `/var` → `/private/var` so paths compare equal with scanner-recorded paths.
- `LookupService` takes `requestInterval`/`backoffBase` so tests run at 0s;
  production defaults are 1s.
