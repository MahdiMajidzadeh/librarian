# CLAUDE.md

Librarian — native macOS 14+ SwiftUI app that catalogs a folder of ebooks
**in place** (no files moved, only renamed with preview + undo). Spec lives in
[requirements.md](requirements.md); FR/NFR numbers in code comments refer to it.

## Context workflow — mandatory for every change

Living docs live in [_contexts/](_contexts/README.md) (overview, development,
features, logic). For **every** development task:

1. **Before coding**, read the relevant `_contexts` file(s). If the request
   fits the documented design/invariants, proceed.
2. If it **conflicts** with a documented invariant or design decision, stop
   and ask the user before writing code.
3. **After coding**, update the affected `_contexts` file(s) to match the code.
4. **Always finish by building** (`swift build`; run `swift run
   bookshelf-tests` when Kit logic changed) and smoke-check the app launches.

## Toolchain — read this first

This machine has **no Xcode**, only Command Line Tools (Swift 5.9.2). Consequences:

- Build with `swift build`. **Never** use `xcodebuild`, `.xcodeproj`, or asset catalogs.
- **XCTest is unavailable.** Tests are a plain executable target — do NOT add
  `.testTarget`s or `import XCTest`. The `xcrun … XCTest paths` warning on
  every build is noise; ignore it.
- GRDB is pinned to **6.x** (`"6.29.0"..<"7.0.0"`) — GRDB 7 needs Swift 5.10+.
  ZIPFoundation pinned to 0.9.x. Don't bump majors.
- Swift 5.9 concurrency: `@Sendable` closures can't mutate captured vars —
  compute diffs/plans *before* entering `database.writer.write { }` blocks
  (see `LibraryScanner.scan` for the pattern). Shared-state classes use
  `NSLock` + `@unchecked Sendable` (see `GroupingEngine`).

## Commands

```bash
swift build                                # debug build
swift run bookshelf-tests                  # full test suite (66 tests)
swift run bookshelf-tests --seed <dir>     # generate demo library of fixture books
Scripts/make-app.sh                        # release build → Librarian.app (unsigned)
open Librarian.app
```

Verify UI changes by launching the binary and checking it stays alive:
`.build/debug/BookShelf & sleep 3; kill -0 $!`

## Architecture

Two targets, strict boundary: **BookShelfKit** (all logic, zero AppKit/SwiftUI
dependencies in behavior — headless-testable) and **BookShelf** (SwiftUI shell).
If it can be tested without a window, it belongs in the Kit.

```
Sources/BookShelfKit/
  Database/   AppDatabase (GRDB migrations v1,v2…), Records.swift (Book, BookFile,
              ProvenanceRecord, RenameLogEntry, SettingRow)
  Scanning/   LibraryScanner (enumerate/diff/write), ScanPipeline (scan → parse →
              group → apply metadata + covers), FolderAccess (bookmarks)
  Grouping/   Normalizer, GroupingEngine (3-rule matcher), GroupingOperations
              (manual merge/split)
  Metadata/   EpubParser, PdfParser, MobiParser, MetadataExtractor (dispatch),
              CoverCache (600px grid JPEG + original)
  Lookup/     MetadataProvider protocol, OpenLibraryProvider (primary, keyless),
              GoogleBooksProvider (needs user API key), LookupService
              (rate limit + backoff + resumable batches), MetadataApplier
  Rename/     RenameTemplate (tokens + {cond? …} segments), RenamePlanner
              (collisions/no-ops/exclusions), RenameExecutor (journal + undo)
  Export/     Exporters.swift (JSONExporter schema v1, CSVExporter with BOM)
Sources/BookShelf/
  AppModel.swift        @Observable store; GRDB ValueObservation drives `items`
  Views/                ContentView (toolbar/status), LibraryGridView,
                        LibraryTableView, BookDetailView, BookEditSheet,
                        CandidatePickerSheet, RenamePreviewSheet, SettingsView
Sources/BookShelfTests/ TestHarness.swift + one *Tests.swift per subsystem
```

## Invariants — do not break

- **The folder is the source of truth for files; the DB for metadata.** Never
  move/copy user files; renames stay within the same directory via
  `FileManager.moveItem` + DB path update in the same transaction.
- **Rescans never lose data**: unchanged files (path+size+mtime `contentKey`)
  are skipped; resolved metadata is never discarded; vanished files are
  *flagged* missing, deleted only by explicit purge.
- **Field precedence**: manual > online (fill-empty by default, overwrite only
  by Settings toggle) > embedded > filename. Every field write records
  provenance in the `provenance` table. Manual edits are never overwritten.
- **Manual grouping wins**: books with `manualGroup = true` are never
  auto-joined by `GroupingEngine`; merge/split decisions must survive rescans.
- **Renames are previewable and undoable**: any new rename path must go
  through `RenamePlanner` → preview sheet → `RenameExecutor` journal.
- **Unicode/RTL is first-class** (Persian titles are the test case): filename
  truncation is 255 *UTF-8 bytes* on a character boundary; CSV keeps its BOM;
  never transliterate.
- **Offline-first**: network calls only in Lookup/, only on explicit user
  action, only to Open Library / Google Books.

## Conventions & gotchas

- Schema changes = **new numbered GRDB migration** in `AppDatabase.migrator`
  (never edit v1). Array columns (`authors`, `tags`) are JSON text via Codable.
- New settings go through `database.setting(_:)` / `setSetting` string KV +
  a control in `SettingsView`; read via `AppModel.settingValue`.
- Test fixtures are **generated in code** (epub via ZIPFoundation, PDF via
  CoreGraphics, MOBI byte-by-byte) — never commit binary fixtures. Shared
  demo-library builder: `Fixtures.seedDemoLibrary(at:)`.
- Tests use the harness helpers (`expect`, `expectEqual`, `withTempDirectory`)
  and register in `main.swift` via `await xxxTests(runner)`.
- Grid covers must render inside a fixed-frame overlay (`CoverView`) — a bare
  `.aspectRatio(.fill)` image leaks its natural width into `LazyVGrid` layout
  and tiles overlap. Cover files are rewritten in place; `CoverImageLoader`
  cache keys include mtime for that reason.
- Cover quality is ranked (`ScanPipeline.coverRank`): epub/mobi/azw3 embedded
  covers replace PDF first-page renders, never the reverse.
- **Tags never come from embedded metadata** (PDF Keywords / dc:subject /
  EXTH are junk-prone): only online lookup and manual edits set tags;
  scan/re-extract clear embedded-sourced tags from old rows.
- Parse failures are non-fatal: book stays visible with
  `metadataStatus = .unresolved` + `parseErrorNote`.
- Commit style: conventional commits (`feat(scope):`, `fix(ui):`, `chore:`),
  body explains the FR/§ being satisfied.

## Backlog markers

P1 (all shipped): FSEvents folder watching (`FolderWatcher`, Settings toggle),
per-file CSV mode (`CSVExporter.Mode.perFile`), rename dry-run export
(`RenamePlanExporter`).
P2: metadata write-back into files, format conversion, content-hash dedupe.
Sandbox/codesigning: bookmark code paths exist but the shipped bundle is
unsigned — revisit when Xcode is available.
