# 01 — What Librarian is

Librarian (working title "Book Shelf") is a **native macOS 14+ SwiftUI app**
that catalogs a user-designated folder of ebooks **in place**. It is the
anti-Calibre: it never moves, copies, or restructures the user's files — it
only *reads* them, *groups* multi-format copies of the same title into one
logical book, *enriches* them with metadata and covers, optionally *renames*
them against a template (with preview and undo), and *exports* the catalog as
JSON/CSV.

The full spec is [requirements.md](../requirements.md); FR/NFR numbers in code
comments refer to sections of that document.

## Problem it solves

Years of accumulated ebooks in one folder: inconsistent names, duplicate
formats of the same title (epub + pdf + mobi), no visible metadata. Existing
tools (Calibre) impose their own managed library folder; many users refuse
that. Librarian works on the folder as-is.

## Goals (v1)

- Scan 2,000+ files and show a grouped, metadata-rich library in < 30 s on
  Apple Silicon.
- Auto-group ≥ 95% of multi-format duplicates correctly.
- Rename any selection collision-safely with zero data loss, undoable.
- Resolve metadata + cover for ≥ 90% of books (embedded first, online
  lookup fallback).
- Complete well-formed JSON/CSV export at any time.

## Non-goals (v1)

No reader view (double-click opens the system default app), no moving files,
no format conversion, no sync/cloud, no writing metadata back into book files
(P2).

## Hard invariants — never break these

1. **Folder is source of truth for files; the DB for metadata.** Files are
   never moved/copied; renames stay in the same directory via
   `FileManager.moveItem` + DB path update in one transaction.
2. **Rescans never lose data**: unchanged files (path+size+mtime `contentKey`)
   are skipped; resolved metadata is never discarded; vanished files are
   flagged missing, deleted only by explicit purge.
3. **Field precedence**: manual > online (fill-empty by default; overwrite
   only via Settings toggle) > embedded > filename. Every field write records
   provenance. Manual edits are never overwritten.
4. **Manual grouping wins**: `manualGroup = true` books are never auto-joined;
   merge/split decisions survive rescans.
5. **Renames are previewable and undoable**: every rename path goes through
   `RenamePlanner` → preview sheet → `RenameExecutor` journal.
6. **Unicode/RTL first-class** (Persian titles are the test case): filename
   truncation is 255 UTF-8 bytes on a character boundary; CSV keeps its BOM;
   never transliterate.
7. **Offline-first**: network calls only from `Lookup/`, only on explicit user
   action, only to Open Library / Google Books.
