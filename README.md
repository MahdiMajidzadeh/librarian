# Librarian

A native macOS app that catalogs a folder of ebooks **in place** — no library
takeover, no moved files. It groups multi-format copies (epub + pdf + mobi)
into one logical book, extracts embedded metadata and covers, enriches books
via Open Library (and optionally Google Books), renames files to your
template with a mandatory preview and one-click undo, and exports the catalog
as JSON or CSV.

Built against [requirements.md](requirements.md) (v1.0 draft, all P0 scope).

## Requirements

- macOS 14+
- Swift toolchain (works with Command Line Tools alone — no Xcode needed)

## Build & run

```bash
swift build                      # debug build
Scripts/make-app.sh              # release build → Librarian.app
open Librarian.app
```

## Tests

Command Line Tools installs don't ship XCTest, so tests run as a plain
executable:

```bash
swift run bookshelf-tests
```

63 tests cover the database layer, scanner, grouping engine, all three
format parsers (fixtures generated programmatically), lookup service
(stubbed HTTP), rename engine, and exporters.

### Demo library

Seed a folder with generated fixture books (the Dune grouping-acceptance
trio, a Persian epub, and friends) to try the app end-to-end:

```bash
swift run bookshelf-tests --seed ~/BookShelfDemo
open Librarian.app       # then choose ~/BookShelfDemo as the library folder
```

## Architecture

```
Sources/
  BookShelfKit/          # headless core — everything testable via CLI
    Database/            # GRDB schema, migrations, records (book, bookFile,
                         #   provenance, renameLog, setting)
    Scanning/            # recursive scanner, incremental rescan, scan pipeline,
                         #   security-scoped folder access
    Grouping/            # normalizer + 3-rule grouping engine, merge/split
    Metadata/            # epub OPF, PDF (PDFKit), MOBI/AZW3 EXTH parsers,
                         #   cover cache (600px grid + original)
    Lookup/              # Open Library + Google Books providers, rate-limited
                         #   resumable batch resolution, provenance
    Rename/              # template engine (tokens + conditionals), planner
                         #   (collisions), executor (journal + undo)
    Export/              # JSON schema v1, CSV with BOM
  BookShelf/             # SwiftUI app (grid/table, detail, picker, preview,
                         #   settings)
  BookShelfTests/        # test harness + suites (XCTest-free)
```

Key behaviors:

- **Files never move.** Only names change, only after a preview, and the last
  batch is always undoable (journal survives restart — it lives in SQLite).
- **Incremental rescans** key files by path + size + mtime; resolved metadata
  is never discarded. Deleted files are greyed out, purged only on request.
- **Provenance per field** (`embedded` / `open_library` / `google_books` /
  `manual` / `filename`) — manual edits always win over automatic passes.
- **Offline-first:** online lookup runs only when you ask (FR-3.1).
- **Unicode/RTL throughout:** Persian titles are first-class — in filenames
  (255-byte-safe truncation), the UI, and exports (CSV ships a UTF-8 BOM for
  Excel).

## Settings

Template tokens for renaming: `{title}` `{author}` `{authors}` `{author_sort}`
`{year}` `{series}` `{series_index}` `{isbn}` `{language}` `{publisher}`
`{ext}`, plus conditional segments — `{series? ({series} #{series_index})}`
renders only when the book has a series. Default:
`{author} - {title}.{ext}`.

Google Books is optional: paste an API key in Settings to add it as a
provider; Open Library needs no key and is always available.

## Known limitations (v1)

- No sandbox/codesigning in the default build (the security-scoped bookmark
  path is in place for a future signed build).
- Metadata is stored in the app database only — never written back into the
  book files (P2 in the spec).
