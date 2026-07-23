# CLAUDE.md

Librarian — native macOS 14+ SwiftUI app that catalogs a folder of ebooks
**in place** (no files moved, only renamed with preview + undo). Spec lives in
[requirements.md](requirements.md); FR/NFR numbers in code comments refer to
it. Deliberate deviations from the spec (no tags, always-open sidebar,
side-by-side candidate picker, duplicate-format filter, cover-from-group) are
listed in [_contexts/01-overview.md](_contexts/01-overview.md).

## Context workflow — mandatory for every change

Living docs live in [_contexts/](_contexts/README.md) (overview, development,
features, logic). For **every** development task:

1. **Before coding**, read the relevant `_contexts` file(s). If the request
   fits the documented design/invariants, proceed.
2. If it **conflicts** with a documented invariant or design decision (e.g.
   would move user files, overwrite manual edits, bypass the rename preview),
   stop and ask the user before writing code.
3. **After coding**, update the affected `_contexts` file(s) to match the code.
4. **Always finish by building** (`swift build`, `swift test`) and
   smoke-check the app launches (see Commands).

## Test-case catalog — [test-case.md](test-case.md) is the source of truth

Every XCTest method in `Tests/LibrarianKitTests/` maps 1:1 to a case ID in
`test-case.md` (DB-xx, SCAN-xx, GRP-xx, EPUB/PDF/MOBI-xx, META-xx, LOOK-xx,
REN-xx, EXP-xx, WATCH-xx, E2E-xx). **If `test-case.md` is updated, rewrite
the tests to match it**; any test-code change must update the catalog in the
same commit.

## Toolchain

Xcode 26.6 / Swift 6.3, but the project is **SPM-only** — no `.xcodeproj`,
no asset catalogs. Tools-version 6.0 with Swift 5 language mode on all
targets. GRDB 7.x + ZIPFoundation 0.9.x. The app ships unsandboxed/unsigned
via `Scripts/make-app.sh`; security-scoped bookmark code must keep degrading
gracefully (see `FolderAccess`).

## Commands

```bash
swift build                          # debug build
swift test                           # full suite (133 tests, all offline)
swift run librarian-seed <dir>       # generate demo library for manual testing
Scripts/make-app.sh                  # release build → Librarian.app (icon.png → icns)
open Librarian.app
.build/debug/Librarian & sleep 3; kill -0 $!   # smoke-check UI launch
```

## Architecture

Strict two-layer split: **LibrarianKit** (Database, Scanning, Grouping,
Metadata, Lookup, Rename, Export — zero AppKit/SwiftUI, headless-testable)
and **Librarian** (SwiftUI shell: `AppModel` + `Views/`). If it can be tested
without a window, it belongs in the Kit. `LibrarianFixtures` (epub/pdf/mobi
builders) is shared by the test suite and `librarian-seed`, never by the app.

## Gotchas

- GRDB `read`/`write` need `await` inside `async` functions (async overloads
  shadow the sync ones).
- No `Dictionary[key, default: …]` where the default closure touches the same
  dictionary — Swift exclusivity crash (bit us in `RenamePlanner`).
- Lookup tests use `StubProvider`; the suite must never hit the network.
- Paths: test temp dirs are canonicalized (`/var` → `/private/var`) in
  `makeTempDir()`; keep comparisons canonical.
