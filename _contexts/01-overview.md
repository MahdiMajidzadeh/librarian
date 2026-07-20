# 01 — Overview

## What Librarian is

Librarian is a native macOS 14+ SwiftUI app that catalogs a folder of ebooks
**in place**. It scans a user-chosen folder recursively, groups multi-format
copies of the same title into one logical book, extracts embedded metadata
and covers (epub/pdf/mobi/azw3), optionally enriches books via Google Books /
Open Library, renames files against a user template (preview-first, undoable),
and exports the catalog as JSON or CSV. Spec: [requirements.md](../requirements.md);
FR/NFR numbers in code comments refer to it.

## The problem it solves

Years of accumulated ebooks in one folder: inconsistent names, duplicate
formats of the same title, no visible metadata. Calibre solves this but takes
ownership of the files (moves them into its managed library). Librarian never
moves a file — the folder stays yours; only file *names* change, and only
after an explicit preview.

## Hard invariants (never break without asking the user)

1. **Files are never moved, copied, or deleted** — only renamed, in the same
   directory, via the preview + undo pipeline.
2. **A rename is never destructive**: collisions get " (2)" suffixes, never
   overwrite; every batch lands in a persistent undo journal.
3. **Manual user edits always win**: fields with `manual` provenance are
   never overwritten by scans or online lookups; manual covers are never
   replaced automatically.
4. **Rescans never discard resolved metadata** (FR-1.4). Deleted files are
   marked *missing*, not removed (FR-1.5); purge is an explicit user action.
5. **Manual grouping decisions (merge/ungroup) persist across rescans** and
   beat automatic grouping (FR-2.4).
6. **Online lookup is never automatic** — always an explicit user action; the
   app is fully usable offline (FR-3.1, NFR-3).
7. **Unicode/RTL is first-class**: Persian titles must survive parsing,
   renaming (255-*byte* APFS cap, no transliteration), CSV export (UTF-8 BOM).
8. **No telemetry**; the only network calls are the two metadata APIs on user
   action (NFR-6).

## Deliberate deviations from requirements.md (user-requested)

- **No tags feature** — not in the data model, UI, search, filters, or exports.
- **The detail sidebar is always visible** (no layout shift on selection).
- The lookup candidate picker shows the **local book side-by-side** with
  online candidates (cover, title, author) for verification.
- Extra filter: books whose group contains **multiple files of the same
  format** ("Duplicate formats").
- The user can **pick a book's cover from any file in its group**.

## Non-goals (v1)

No reader view (double-click opens the system default app), no folder
reorganization, no format conversion, no cloud/sync, no metadata write-back
into book files.
