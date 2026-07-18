# Requirements — Book Shelf (working title)

**Version:** 1.0 draft
**Date:** 2026-07-18
**Platform:** macOS 14+ (native, Swift / SwiftUI)
**Status:** For review

---

## 1. Problem Statement

Ebook collections accumulated over years end up in a single folder with inconsistent file names, duplicate formats of the same title (epub + pdf + mobi), and no visible metadata. Finding a book, knowing which formats you own, or exporting an inventory of the collection currently requires manual work. Existing tools (Calibre) solve this but impose their own library structure and move/copy files into a managed database folder, which many users don't want.

Book Shelf reads a user-designated folder **in place**, groups multi-format copies into a single logical book, normalizes file names against a user-defined template, enriches each book with metadata and cover art (embedded first, online lookup as fallback), and exports the catalog as JSON or CSV.

## 2. Goals

1. Scan a folder of N books (target: 2,000+ files) and present a grouped, metadata-rich library view in under 30 seconds on Apple Silicon.
2. Correctly group ≥ 95% of multi-format duplicates into a single book entry without user intervention.
3. Rename any selection of files to the user's template with zero data loss (rename in place, collision-safe, undoable).
4. Resolve metadata + cover for ≥ 90% of books via embedded data or online lookup.
5. Produce a complete, well-formed JSON/CSV export of the library at any time.

## 3. Non-Goals (v1)

- **Reading books.** No reader view; double-click opens the file in the system default app. Out of scope — separate product category.
- **Moving or reorganizing folder structure.** Files stay where they are; only file *names* change. Keeps the tool non-destructive and trust-preserving.
- **Format conversion** (epub → mobi etc.). Complex dependency surface (Calibre CLI); revisit in v2.
- **Sync / multi-device / cloud library.** Local-first, single Mac.
- **Editing embedded metadata inside the book files.** v1 stores corrections in the app's own database only; writing back into epub/pdf containers is a P2.

## 4. Supported Formats

| Tier | Formats | Notes |
|---|---|---|
| Full support (metadata + cover extraction) | `epub`, `pdf`, `mobi`, `azw3` | Embedded metadata parsed natively |
| Recognized (grouped + renamable, no embedded parsing) | `djvu`, `cbz`, `cbr`, `fb2`, `txt` | Metadata via online lookup or filename inference only |

Unknown extensions are ignored by the scanner (configurable ignore list in Settings).

## 5. User Stories

- As a collector, I want to point the app at my books folder and see every title once — with badges for each format I own — so I can understand my collection at a glance.
- As a collector, I want files renamed to a consistent pattern I define, so the folder is readable in Finder even without the app.
- As a collector, I want the app to fetch missing covers and metadata online, so old files with names like `book_final2.pdf` become identifiable.
- As a collector, I want to preview every rename before it happens, so I never lose track of a file.
- As a data-oriented user, I want a JSON/CSV export of the full catalog, so I can analyze or back up my inventory elsewhere.
- As a cautious user, I want an undo for the last rename batch, so a bad template choice is recoverable.
- As a user with a growing library, I want a rescan to pick up new/removed files without re-fetching metadata for books it already knows.

## 6. Functional Requirements

### 6.1 Library Folder & Scanning — P0

- FR-1.1 User selects exactly one root folder via `NSOpenPanel`; access persisted with a security-scoped bookmark (sandbox-compatible).
- FR-1.2 Scan is recursive through subfolders. Hidden files and the ignore-list extensions are skipped.
- FR-1.3 Scan runs on a background queue with a determinate progress indicator (files processed / total).
- FR-1.4 Rescan is incremental: files are keyed by path + size + modification date; unchanged files are not re-parsed, and previously resolved metadata is never discarded by a rescan.
- FR-1.5 Files deleted from disk are marked *missing* in the library (grey state), not silently removed; user can purge missing entries explicitly.
- FR-1.6 Optional folder watching (FSEvents) to auto-detect additions — **P1**.

**Acceptance:** Given a folder with 2,000 mixed files, when the user triggers a scan, then the library view is populated, progress is shown throughout, and a second rescan with no changes completes in < 3 seconds.

### 6.2 Multi-Format Grouping — P0

Chosen model: **one logical book, multiple file entries, format badges.**

- FR-2.1 Grouping key, in priority order:
  1. Identical ISBN in embedded metadata.
  2. Normalized *(title, author)* match from embedded metadata (case-folded, diacritics-stripped, punctuation-removed).
  3. Normalized filename stem match (extension removed, separators `._-` collapsed, edition/format noise words stripped: `v2`, `final`, `(1)`, `ocr`, etc.).
- FR-2.2 Library view shows each book once with badges per owned format (e.g. `EPUB · PDF · MOBI`).
- FR-2.3 Book detail view lists each underlying file: path, format, size, modification date, per-file open/reveal-in-Finder actions.
- FR-2.4 Manual override: user can **merge** two book entries or **split** a file out of a group. Manual decisions persist across rescans and take precedence over automatic grouping.
- FR-2.5 Confidence signal: groups formed only by filename similarity (rule 3) are marked with a subtle "auto-grouped" indicator so the user can review.

**Acceptance:** Given `dune.epub`, `Dune - Frank Herbert.pdf`, and `dune_v2.mobi` in the folder, when scanned, then one book entry appears with three format badges, marked auto-grouped if no embedded metadata confirmed the match.

### 6.3 Metadata & Covers — P0

Resolution pipeline per book:

1. **Embedded (offline):** epub OPF (`dc:title`, `dc:creator`, `dc:identifier`, `dc:language`, `dc:publisher`, `dc:date`, description, subjects) and embedded cover; PDF Info/XMP dictionary + first-page render as cover fallback; MOBI/AZW3 EXTH header + embedded cover record.
2. **Online lookup:** query **Google Books API** first, **Open Library** as fallback. Query by ISBN when available, otherwise `title + author`. Fetch: canonical title, authors, publisher, publish date, ISBN-10/13, page count, language, categories, description, cover image (largest available).
3. **Filename inference:** last resort — parse `Author - Title` / `Title - Author` patterns from the filename to seed the online query.

Requirements:

- FR-3.1 Embedded metadata is extracted during scan; online lookup is a separate, explicit step (per book, per selection, or "resolve all missing") — never automatic on scan, so the app stays fully usable offline.
- FR-3.2 Field-level precedence: online data fills **empty** fields by default; a Settings toggle switches to "online overwrites embedded". User manual edits always win and are never overwritten.
- FR-3.3 Every field records its provenance (`embedded` / `google_books` / `open_library` / `manual` / `filename`), visible in the detail view and included in JSON export.
- FR-3.4 Ambiguous lookups (multiple candidate matches, low title similarity) present a candidate picker instead of silently choosing.
- FR-3.5 Covers are cached locally in Application Support as JPEG (max 600 px long edge for grid; original kept for detail/export path).
- FR-3.6 Rate limiting and retry with backoff for both APIs; batch "resolve all" is resumable after failure.
- FR-3.7 Editable fields in detail view: title, authors, series + series index, publisher, year, language, ISBN, tags, description, cover (replace from file or re-fetch).

**Acceptance:** Given a book with no embedded metadata and filename `Herbert - Dune.epub`, when the user runs online resolution, then the app queries by inferred title/author, presents the Google Books match, and on confirmation populates all fields with provenance `google_books`.

### 6.4 Rename Engine — P0

Chosen model: **rename in place**, template-driven, preview-first.

- FR-4.1 Template defined in Settings with tokens:
  `{title}`, `{author}`, `{authors}`, `{author_sort}` (Last, First), `{year}`, `{series}`, `{series_index}`, `{isbn}`, `{language}`, `{publisher}`, `{ext}`
  plus literal text. Default: `{author} - {title}.{ext}`
- FR-4.2 Conditional segments for missing data: `{series? ({series} #{series_index})}` renders only when the book has a series. Tokens resolving to empty collapse cleanly (no dangling ` - ` or `()`).
- FR-4.3 Live template preview in Settings using three sample books from the actual library.
- FR-4.4 Sanitization: strip `/:` and other illegal characters, collapse whitespace, enforce max filename length (APFS 255 bytes — relevant for long Persian/UTF-8 titles), preserve Unicode as-is (no forced transliteration).
- FR-4.5 Collision handling: if the target name exists, append ` (2)`, ` (3)`… ; never overwrite. Collisions are highlighted in preview.
- FR-4.6 **Mandatory preview sheet** before execution: table of `current name → new name`, per-row include/exclude checkboxes, collision and no-op rows flagged. Multi-format books rename all their files consistently in one operation.
- FR-4.7 Rename executes via `FileManager.moveItem` within the same directory; the app's database updates paths atomically with the file operation.
- FR-4.8 **Undo last batch:** rename journal (old path ↔ new path) persisted per batch; single-click revert of the most recent batch. Journal survives app restart.
- FR-4.9 Books with unresolved required tokens (e.g. template needs `{author}` but author is unknown) are excluded from the batch and listed with the reason.

**Acceptance:** Given 50 selected books and template `{author} - {title} ({year}).{ext}`, when the user opens the rename preview, then every proposed name is shown; when 2 rows collide, they are flagged and suffixed; when the user confirms, files are renamed in place and one Undo entry is created that fully restores prior names.

### 6.5 Export — P0

- FR-5.1 Export scope: entire library or current selection/filter result.
- FR-5.2 **JSON**: array of book objects — full metadata, provenance map, tags, and nested `files[]` (path, format, size, checksum-optional, modified date), plus `cover_path` (relative to an optional exported covers folder). Schema versioned (`"schema_version": 1`).
- FR-5.3 **CSV**: one row per book (multi-value fields joined with `; `, formats as `epub;pdf`), UTF-8 **with BOM** so Excel renders Persian/Unicode correctly. Optional alternate mode: one row per file — **P1**.
- FR-5.4 Optional "include cover images" checkbox for JSON export → writes covers to a sibling `covers/` folder.
- FR-5.5 Export runs in background with progress; output location chosen via save panel.

**Acceptance:** Given a 500-book library, when exporting JSON with covers, then the resulting file validates against the schema, every book's `files[]` matches disk reality, and covers resolve via the relative paths.

### 6.6 Library UI — P0

- FR-6.1 Grid view (cover-first) and table view (columns: title, author, formats, year, size, status), toggleable.
- FR-6.2 Search-as-you-type across title, author, series, ISBN, tags, filename.
- FR-6.3 Filters: format, metadata status (complete / partial / unresolved), missing-on-disk, auto-grouped, tag.
- FR-6.4 Sort: title, author sort, year, date added, file size.
- FR-6.5 Multi-select with contextual actions: resolve metadata, rename, export selection, merge, open in Finder.
- FR-6.6 Status chips per book: metadata source, unresolved warning, missing-file warning.

### 6.7 Settings — P0

- Library folder (change re-prompts for scan).
- Rename template editor with live preview (6.4).
- Metadata precedence toggle (fill-empty vs. overwrite) and provider order.
- Extension ignore list.
- CSV delimiter (`,` / `;` / tab) and multi-value separator.
- Cover cache size display + clear cache.

## 7. Data Model (app database — SQLite via GRDB or SwiftData)

```
Book        id, title, title_sort, authors[], author_sort, series, series_index,
            publisher, year, language, isbn10, isbn13, description, tags[],
            cover_cache_path, metadata_status, group_method, created_at, updated_at
BookFile    id, book_id, path, format, size_bytes, modified_at, missing_flag
Provenance  book_id, field, source, fetched_at
RenameLog   batch_id, file_id, old_path, new_path, executed_at, reverted_flag
Settings    key, value
```

The database lives in Application Support; the folder on disk remains the source of truth for files, the database is the source of truth for metadata corrections and grouping decisions.

## 8. Non-Functional Requirements

- **NFR-1** Scan of 2,000 files < 30 s (M-series, local SSD); UI never blocks.
- **NFR-2** All destructive-adjacent operations (rename) are previewable and the last batch is undoable.
- **NFR-3** Fully functional offline except online metadata lookup, which degrades gracefully.
- **NFR-4** Full Unicode/RTL correctness in UI, filenames, and exports (Persian titles are a first-class test case).
- **NFR-5** App Sandbox compatible (security-scoped bookmarks); no elevated permissions.
- **NFR-6** No telemetry; network calls only to the two metadata APIs, only on user action.

## 9. Edge Cases

- Same title, different books (e.g., two authors' "Rework") → grouping rule 3 must require author-token agreement when authors are inferable; otherwise keep separate and let the user merge.
- Multi-author files with inconsistent author ordering across formats → normalize author sets, not sequences, for matching.
- Books inside nested subfolders that would collide after rename (same directory only matters per-file; cross-folder duplicates remain separate files under one book).
- Corrupt/DRM'd files → parse failures are non-fatal; book appears with `unresolved` status and a parse-error note.
- Folder moved/renamed outside the app → bookmark resolution fails gracefully with a re-select prompt; database is preserved and re-linked by relative path where possible.
- ISBN present but wrong in embedded metadata → candidate picker (FR-3.4) shows title similarity score so the user can reject.

## 10. Open Questions

1. **(Product)** Should v1 include tags/collections created by the user, or is search + filters enough? *(Non-blocking — data model already reserves `tags[]`.)*
2. **(Engineering)** SwiftData vs. GRDB/SQLite — SwiftData is simpler but migration and provenance-table queries may favor GRDB. *(Blocking for M1 start.)*
3. **(Product)** Google Books API key: ship keyless (low quota) or require user-supplied key in Settings? *(Non-blocking — Open Library needs no key and can be default.)*
4. **(Product)** Should renaming also offer a "dry-run export" (CSV of proposed renames) for very large batches? *(Non-blocking, cheap P1.)*

## 11. Phasing

| Milestone | Scope |
|---|---|
| **M1 — Core shelf** | Folder selection, scan, grouping, grid/table UI, embedded metadata + covers |
| **M2 — Enrichment** | Online lookup pipeline, candidate picker, provenance, manual editing |
| **M3 — Rename + Export** | Template engine, preview, undo journal, JSON/CSV export |
| **P1 backlog** | Folder watching, per-file CSV mode, rename dry-run export |
| **P2 backlog** | Write-back of metadata into files, format conversion, duplicate-content detection by hash |
