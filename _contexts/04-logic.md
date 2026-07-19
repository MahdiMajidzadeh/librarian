# 04 — How the logic works

## Scan pipeline (`Scanning/`)

`ScanPipeline` orchestrates: **enumerate → diff → parse → group → apply
metadata + covers**.

1. `LibraryScanner` enumerates the folder, computes each file's `contentKey`
   (path + size + mtime), and diffs against `book_file` rows: new files are
   inserted, changed files re-parsed, untouched files skipped, vanished files
   get `missingFlag = true` (never auto-deleted). The diff/plan is computed
   *before* the GRDB write block (Swift 5.9 `@Sendable` capture rule).
2. `MetadataExtractor` dispatches by extension to `EpubParser` /
   `PdfParser` / `MobiParser`. Failures are caught per file → book still
   appears with `metadataStatus = .unresolved` + `parseErrorNote`.
3. `GroupingEngine` assigns each parsed file to a logical `Book` (below).
4. Metadata is applied field-by-field under the precedence rules, covers are
   cached via `CoverCache`, and every field write inserts a
   `ProvenanceRecord` (field, source, timestamp).

## Grouping (`Grouping/`)

Rule priority in `GroupingEngine` (first match wins), producing
`GroupMethod` per book:

1. **isbn** — identical embedded ISBN.
2. **metadata** — normalized (title, author-set) equality from embedded
   metadata. `Normalizer` lowercases, strips diacritics/punctuation/edition
   noise, and is Unicode-aware (Persian works).
3. **filename** — normalized filename-stem candidates with author-token
   agreement (spec §9). Books grouped this way with > 1 file are what the UI
   calls **auto-grouped** — the least certain tier, hence filterable.
4. **single** — one file, no grouping applied.
5. **manual** — user merge/split via `GroupingOperations`; sets
   `manualGroup = true`, which `GroupingEngine` treats as untouchable on
   every future rescan. Method rank (manual 5 > isbn 4 > metadata 3 >
   filename 2 > single 1) decides which method label a merged group keeps.

## Metadata precedence (`Lookup/MetadataApplier`, `ScanPipeline`)

Per field: **manual > online > embedded > filename**. Online values apply
under the `applyPolicy` setting — `fillEmpty` (default: only blank fields)
or overwrite (still never over manual). Provenance rows make every value
auditable in the detail view. `metadataStatus` is derived: `complete` needs
title + author + year + cover; `partial` some fields; `unresolved` nothing
beyond the filename.

## Online lookup (`Lookup/`)

`MetadataProvider` protocol with two implementations: `OpenLibraryProvider`
(primary, keyless) and `GoogleBooksProvider` (requires `googleBooksAPIKey`
setting). `LookupService` runs explicit-user-action batches with rate
limiting + exponential backoff, is resumable, and emits candidates. A single
confident candidate applies directly; ambiguity queues a
`CandidatePickerSheet` (`AppModel.pendingPicker` / `pickerQueue`). Covers
downloaded during lookup go through the same ranked `CoverCache` path.

## Rename (`Rename/`)

1. `RenameTemplate.parse` turns the template string into segments: literals,
   `{token}`s, and conditionals `{guard? …}` (inner renders only when the
   guard token has a value). Unknown tokens are parse errors; missing
   required tokens exclude the file from the plan (FR-4.9).
2. `RenamePlanner` builds a `RenamePlanItem` per file: target name sanitized,
   truncated to 255 UTF-8 bytes on a character boundary, then classified —
   no-op, collision (with disk or with another plan item), or renameable.
3. UI always shows `RenamePreviewSheet`; nothing renames without it.
4. `RenameExecutor` performs `FileManager.moveItem` + DB path update in the
   same transaction per file and journals the batch (`rename_log`), enabling
   **undo** of the last batch. `RenamePlanExporter` writes a dry-run report.

## Covers (`Metadata/CoverCache`)

Stored outside the library folder: 600 px JPEG for the grid + the original.
`ScanPipeline.coverRank` ranks sources so an embedded epub/mobi/azw3 cover
replaces a PDF first-page render, never the reverse. Cover files are
rewritten in place, so `CoverImageLoader` (app side) keys its cache on
path + mtime.

## Database (`Database/`)

GRDB with numbered migrations (`AppDatabase.migrator`; never edit old ones).
Tables: `book`, `book_file`, `provenance`, `rename_log`, `setting`.
`Book.authors`/`tags` are JSON-encoded text columns. The app observes
books + files via `ValueObservation` → `AppModel.items`; all
search/filter/sort is in-memory over that array (`displayedItems`).

## Export (`Export/Exporters.swift`)

`JSONExporter` (stable schema v1; optional base64 covers) and `CSVExporter`
(UTF-8 BOM preserved for Excel; `Mode.perFile` emits one row per file
instead of per book). Export scope = selection if any, else the current
`displayedItems` filter result.
