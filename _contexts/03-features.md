# 03 — Feature inventory

## Library

- **Choose folder** (NSOpenPanel + security-scoped bookmark, restored on
  launch via `FolderAccess`).
- **Scan** on demand; incremental rescan skips unchanged files by
  `contentKey` (path + size + mtime). Progress reported in the toolbar.
- **Folder watching** (FSEvents via `FolderWatcher`, Settings toggle
  `watchFolder`) — external changes queue a rescan.
- **Formats**: epub, pdf, mobi, azw3 (parsed for metadata) + djvu, cbz, cbr,
  fb2, txt (cataloged only).

## Views & navigation

- **Grid view** (cover tiles) and **table view**, toggle persisted as
  `viewMode` setting.
- **Detail sidebar** (inspector) — always kept open to avoid layout shift;
  shows metadata, file list, provenance; cover can be picked from any file
  in the group.
- **Multi-selection panel** for bulk actions.
- **Edit sheet** (`BookEditSheet`) for manual metadata edits — recorded as
  `manual` provenance, never overwritten later.

## Search / filter / sort (in-memory, in `AppModel.displayedItems`)

- **Search** across title, author, series, ISBN, tags, filename.
- **Filters** (`LibraryFilter`, combinable): by format; by metadata status
  (complete / partial / unresolved); Missing on Disk; Auto-grouped
  (grouped by filename rule); **Duplicate Formats** (≥ 2 files of the same
  format in one group, e.g. two PDFs); by tag.
- **Sort**: title, author, year, date added, file size — ascending or
  descending, ties broken by titleSort for determinism.

## Grouping

- Automatic 3-rule grouping at scan time (see 04-logic).
- **Manual merge / split** (`GroupingOperations`); manual decisions are
  sticky across rescans.

## Metadata & covers

- Embedded metadata parsed from epub (OPF), pdf (Info dict + first-page
  render), mobi/azw3 (EXTH).
- **Online lookup** on explicit user action: Open Library (primary, keyless)
  and Google Books (needs user API key in Settings). Rate-limited, resumable
  batches, candidate picker sheet when ambiguous; completed books can be
  re-resolved through the picker with library context.
- **Apply policy** setting: fill-empty (default) vs overwrite (never
  overwrites manual fields either way).
- **Cover cache**: 600 px grid JPEG + original; quality ranked so
  epub/mobi/azw3 embedded covers beat PDF first-page renders, never the
  reverse.

## Rename

- **Template** with tokens (`{title}`, `{author}`, `{authors}`,
  `{author_sort}`, `{year}`, `{series}`, `{series_index}`, `{isbn}`,
  `{language}`, `{publisher}`, `{ext}`) and conditional segments
  (`{series? ({series} #{series_index})}`). Default:
  `{author} - {title}.{ext}`. Stored in `renameTemplate` setting.
- **Planner** detects collisions, no-ops, missing-token exclusions;
  **preview sheet** always shown; **executor** journals every batch for
  **undo** (menu item). Dry-run plan export available.
- 255 UTF-8-byte filename truncation on character boundaries (Persian-safe).

## Export

- **JSON** (schema v1, optional embedded covers) and **CSV** (UTF-8 BOM,
  Excel-safe), including a per-file CSV mode. Exports the selection, or the
  current filter result when nothing is selected.

## Resilience

- Parse failure → book stays listed, `metadataStatus = .unresolved`,
  `parseErrorNote` shown.
- Missing file → flagged, filterable, removed only by explicit purge.
- Clear-cache recovery, undo state restored on launch.
