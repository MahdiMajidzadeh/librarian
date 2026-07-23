# 03 — Features

## Library & scanning (§6.1)

- One root folder chosen via `NSOpenPanel`; persisted as a security-scoped
  bookmark with plain-path fallback (`FolderAccess`).
- Recursive scan; skips hidden files, unknown extensions, and the
  user-configured ignore list. Formats: full parsing for `epub pdf mobi azw3`;
  `djvu cbz cbr fb2 txt` are recognized (grouped + renamable) only.
- Incremental by path + size + mtime; determinate progress in the status bar;
  a second no-change rescan parses nothing.
- Deleted files turn grey ("missing" chip); *Purge Missing Entries* removes
  them explicitly. Folder watching (FSEvents, debounced) auto-rescans.
- **Catalog backup in the folder**: a hidden `.librarian.sqlite` copy at the
  library root, refreshed (debounced) after every change and on quit. Choosing
  a folder with an empty catalog auto-restores from it — metadata, grouping,
  and rename history survive a wiped Application Support or a move to a new
  Mac (file paths are rebased to the new location; covers re-extract on the
  next scan).

## Grouping (§6.2)

- One logical book ← many files. Automatic rules in priority order:
  ISBN match → normalized (title, author-set) → filename stem (noise words
  stripped, author agreement required).
- Books grouped only by filename show a purple "auto-grouped" link chip and
  can be filtered for review.
- **Merge** (multi-select → "Merge Into One Book"), **Ungroup** (detail
  sidebar / context menu → one book per file), and **per-file split** (the
  scissors button on any file row in the detail sidebar → that one file
  becomes its own book, the rest of the group is untouched). All persist
  across rescans. Books created by ungroup/split are seeded from their file's
  own embedded metadata and cover, so they show a proper title and cover
  immediately (filename guess only as fallback).

## Metadata & covers (§6.3)

- Embedded extraction at scan time: EPUB OPF, PDF Info + first-page render,
  MOBI/AZW3 EXTH + cover record. Parse failures are non-fatal (note chip).
- Online resolution — explicit only: per book, per selection, or "Resolve All
  Missing". Google Books first, Open Library fallback (order configurable).
  Rate-limited with retry/backoff; batch continues past failures.
- Confident single match auto-applies; ambiguous/low-similarity opens the
  **candidate picker**, which shows the local file (cover/title/author/
  filenames) side-by-side with candidates and their similarity score.
- Field precedence: online fills empty fields (default) or overwrites
  (setting); manual edits always win. Every field carries provenance
  (`embedded` / `google_books` / `open_library` / `manual` / `filename`),
  shown as tags in the detail sidebar.
- Covers cache in Application Support (600px grid variant + original).
  Cover menu: use cover from any group file, replace from image file,
  re-fetch online.

## Rename (§6.4)

- Template in Settings with live preview from 3 real library books. Tokens:
  `{title} {author} {authors} {author_sort} {year} {series} {series_index}
  {isbn} {language} {publisher} {ext}`; conditionals `{series? (…)}` collapse
  cleanly when data is missing.
- Sanitization: `/` `:` stripped, whitespace collapsed, 255-byte APFS cap
  (Unicode preserved, truncation on character boundaries).
- **Mandatory preview sheet**: current → new per file, include checkboxes,
  collision rows flagged (auto " (2)" suffix), no-op rows dimmed, excluded
  rows listed with reasons (missing token / missing file).- Execution: same-directory `moveItem`, DB path updated per file, journal row
  per file. **Undo Last Rename Batch** (⌥⌘Z, also in Actions menu) restores
  the most recent batch; the journal survives restarts.

## Export (§6.5)

- Scope: whole library (File menu) or current selection (Actions menu /
  multi-select panel).
- **JSON**: `schema_version: 1`, full metadata, provenance map, nested
  `files[]`, optional `covers/` folder with relative `cover_path`.
- **CSV**: one row per book, UTF-8 **with BOM**, formats as `epub;pdf`,
  configurable delimiter (`,` `;` tab) and multi-value separator.

## Library UI (§6.6)

- Grid (cover-first) and table views, toggle in the toolbar; shared
  search/filter/sort state.
- Search-as-you-type: title, author, series, ISBN, filename.
- Filters: format, metadata status, missing, auto-grouped, **duplicate
  formats** (groups with >1 file of one format). Sorts: title, author, year,
  date added, file size (asc/desc). The filter bar is a fixed-height (34 pt)
  row of pure-SwiftUI controls — button-style toggles, not AppKit checkbox
  toggles, which detached from the row and inflated the bar on first layout.
- Status chips: unresolved (orange ?), auto-grouped (purple link), missing
  (red triangle), parse error (grey note).
- Multi-select (⌘/⇧ in grid, native in table) → the right sidebar becomes the
  bulk-action panel: resolve, rename, merge, export selection. The sidebar is
  always visible and **fixed at 320 pt** (plain HStack, not HSplitView), so
  swapping between placeholder / detail / multi-select never shifts layout.
- Double-click opens the book's first present file in the default app;
  context menu offers open/reveal/resolve/edit/merge/ungroup/rename.

## Settings (§6.7)

- **General**: library folder (change → re-scan), extension ignore list,
  cover cache size + clear.
- **Rename**: template editor with validation + live preview.
- **Metadata**: fill-empty vs overwrite, provider order.
- **Export**: CSV delimiter, multi-value separator.
