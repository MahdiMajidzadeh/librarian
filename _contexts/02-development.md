# 02 — How the app is developed

## Toolchain constraints (read before building anything)

This machine has **no Xcode** — only Command Line Tools with **Swift 5.9.2**.
Consequences:

- Build with `swift build` only. Never `xcodebuild`, `.xcodeproj`, or asset
  catalogs.
- **XCTest is unavailable.** Tests are a plain `executableTarget`
  (`bookshelf-tests`) — never add `.testTarget` or `import XCTest`. The
  `xcrun … XCTest paths` warning on every build is noise.
- **GRDB pinned to 6.x** (`"6.29.0"..<"7.0.0"`) — GRDB 7 needs Swift 5.10+.
  **ZIPFoundation pinned to 0.9.x.** Don't bump majors.
- Swift 5.9 concurrency: `@Sendable` closures can't mutate captured vars —
  compute diffs/plans *before* entering `database.writer.write { }`
  (pattern: `LibraryScanner.scan`). Shared-state classes use `NSLock` +
  `@unchecked Sendable` (pattern: `GroupingEngine`).

## Commands

```bash
swift build                                # debug build
swift run bookshelf-tests                  # full test suite (104 tests)
swift run bookshelf-tests --seed <dir>     # generate demo library of fixture books
Scripts/make-app.sh                        # release build → Librarian.app (unsigned)
.build/debug/BookShelf & sleep 3; kill -0 $!   # smoke-check UI stays alive
```

## Two-target architecture, strict boundary

- **BookShelfKit** — all logic. Zero AppKit/SwiftUI dependency in behavior;
  everything headless-testable. *If it can be tested without a window, it
  belongs in the Kit.*
- **BookShelf** — the SwiftUI shell. `AppModel` (@Observable, @MainActor) is
  the single store; GRDB `ValueObservation` drives its `items` array live
  from the DB. Views render `model.displayedItems` (search + filters + sort
  applied in memory).

```
Sources/BookShelfKit/
  Database/   AppDatabase (GRDB migrations v1,v2,…), Records.swift (Book,
              BookFile, ProvenanceRecord, RenameLogEntry, SettingRow)
  Scanning/   LibraryScanner, ScanPipeline, FolderAccess (bookmarks),
              FolderWatcher (FSEvents)
  Grouping/   Normalizer, GroupingEngine (3-rule matcher), GroupingOperations
  Metadata/   EpubParser, PdfParser, MobiParser, MetadataExtractor (dispatch),
              EmbeddedMetadata, TagSanitizer, CoverCache
  Lookup/     MetadataProvider protocol, OpenLibraryProvider, GoogleBooksProvider,
              LookupService, MetadataApplier
  Rename/     RenameTemplate, RenamePlanner, RenameExecutor, RenamePlanExporter
  Export/     Exporters.swift (JSONExporter schema v1, CSVExporter with BOM)
Sources/BookShelf/
  AppModel.swift   store: items, filters (LibraryFilter), sort, selection,
                   scan/resolve/rename orchestration, undo state
  Views/           ContentView (toolbar/status/filter menu), LibraryGridView,
                   LibraryTableView, BookDetailView, BookEditSheet,
                   CandidatePickerSheet, RenamePreviewSheet, SettingsView,
                   MultiSelectionPanel
Sources/BookShelfTests/  TestHarness.swift + one *Tests.swift per subsystem
```

## Conventions & gotchas

- Schema change = **new numbered GRDB migration** in `AppDatabase.migrator`;
  never edit v1. Array columns (`authors`, `tags`) are JSON text via Codable.
- New settings: string KV via `database.setting(_:)` / `setSetting` + a
  control in `SettingsView`; read via `AppModel.settingValue`. Current keys:
  `applyPolicy`, `googleBooksAPIKey`, `renameTemplate`, `viewMode`,
  `watchFolder`.
- Test fixtures are **generated in code** (epub via ZIPFoundation, PDF via
  CoreGraphics, MOBI byte-by-byte) — never commit binary fixtures. Shared
  builder: `Fixtures.seedDemoLibrary(at:)`. Tests use harness helpers
  (`expect`, `expectEqual`, `withTempDirectory`) and register in `main.swift`
  via `await xxxTests(runner)`.
- **`test-case.md` (repo root) catalogs every test case with a stable ID and
  is the source of truth**: editing the catalog means rewriting the matching
  tests; editing tests means updating the catalog in the same commit. Test
  names in code must equal the catalog's *Test name* column.
- Grid covers render inside a fixed-frame overlay (`CoverView`); a bare
  `.aspectRatio(.fill)` image leaks natural width into `LazyVGrid` and tiles
  overlap. `CoverImageLoader` cache keys include mtime because cover files
  are rewritten in place.
- Parse failures are non-fatal: book stays visible with
  `metadataStatus = .unresolved` + `parseErrorNote`.
- Sheets are presented at window level from `ContentView`, not from inspector
  content (macOS 14 inspector-sheet bug) — e.g. `AppModel.editingItem`.
- Commit style: conventional commits (`feat(scope):`, `fix(ui):`, `chore:`),
  body cites the FR/§ satisfied.

## Backlog

P1 all shipped (FSEvents watching, per-file CSV, rename dry-run export).
P2: metadata write-back into files, format conversion, content-hash dedupe.
Sandbox/codesigning: bookmark code paths exist; bundle ships unsigned until
Xcode is available.
