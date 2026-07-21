# 04 — Logic (how each subsystem works)

## Database (`LibrarianKit/Database`)

GRDB 7 over SQLite in `~/Library/Application Support/Librarian/librarian.sqlite`
(in-memory for tests). Tables (migration `v1`):

- `book` — logical book: title/titleSort, authors (JSON array), authorSort,
  series(+index), publisher, year, language, isbn10/13, description,
  coverCachePath, metadataStatus (`unresolved|partial|complete`), groupMethod
  (`isbn|metadata|filename|manual|single`), parseErrorNote, timestamps.
- `bookFile` — one disk file: path (unique), format, size, mtime,
  missingFlag, **manualGroupId** (manual grouping token), and cached grouping
  keys `embeddedIsbn/embeddedTitleKey/embeddedAuthorKey` so rescans regroup
  without re-parsing unchanged files.
- `provenance` — (bookId, field) → source + fetchedAt. `manual` is sacred.
- `renameLog` — the undo journal: batchId, fileId, oldPath, newPath,
  executedAt, revertedFlag.
- `setting` — key/value; defaults live in `SettingKey.defaults`.

Books with zero files are deleted (`deleteOrphanBooks`); missing files keep
their rows, so their books survive.

## Scanning (`LibraryScanner.scan`)

1. Enumerate the root (skip hidden/ignored/unknown), producing
   `DiskFile(path, format, size, mtime)`.
2. Classify against DB rows by path: unchanged (size+mtime equal → keys
   reused, no parse), changed/new (→ `MetadataExtractor.extract`).
3. **Inside one write transaction over freshly read rows**: build
   `FileIdentity` for every on-disk file and every DB file now missing
   (their group assignment must stay stable), then run
   `GroupingEngine.propose`. Identities/grouping must never be computed from
   the pre-scan snapshot — parsing takes time, and a merge/ungroup committed
   mid-scan would be reconciled against stale tokens, shuffling files into
   wrong books (SCAN-15/16 guard this).
4. In the same transaction, per proposed group:
   - target book = existing book owning the most member files (stable),
     else a new book seeded from merged embedded metadata / filename guess;
   - fill **only empty** fields from embedded data; record provenance;
   - upsert file rows (paths, sizes, missing flags, cached keys);
   - queue covers only for books with `coverCachePath == nil`.
5. Covers are written to the cache after the transaction; the book row is
   pointed at them with `WHERE coverCachePath IS NULL` (never clobbers a
   manual/online cover).

`ScanPipeline` serializes scans on a background queue and coalesces requests
that arrive mid-scan (used by `FolderWatcher`, a debounced FSEvents stream).

## Grouping (`GroupingEngine.propose`)

Union-find over file identities with staged edges:

1. **manual** — files sharing a `manualGroupId` union; manually tokened files
   never take part in automatic edges (so a singleton token = pinned split).
2. **isbn** — identical normalized embedded ISBN, but only when it is
   *plausible* (`ISBN.isPlausible`: valid check digit, not all-one-digit).
   Real-world files share placeholder/junk ISBNs, which must never merge
   strangers (§9, GRP-18).
3. **metadata** — same normalized title key + order-independent author-set key.
4. **filename** — same stem key (separators collapsed, `(…)`/noise words like
   v2/final/ocr stripped). Inside a stem bucket, files with *conflicting*
   author keys are sub-grouped per author; unknown-author files join only
   when there is no conflict (§9 "Rework" case).

Each union records its evidence; flags of an absorbed root fold into the
survivor. Group method = manual if tokened, else the **weakest evidence
used** (`filename` → shown as auto-grouped), else single.

`GroupCommands` implements the user operations: `merge` (survivor = most
complete book, fill-empty from the rest, shared token on all files),
`ungroup` (unique token per file, original book keeps the first file and its
metadata), `split(fileId:)` (one file out of its group into its own book,
unique token, siblings untouched), and `setCover(fromFile:)` /
`setCover(imageData:)` (manual provenance). Books created by ungroup/split
are seeded via `FileSeed`: the file is re-parsed for embedded metadata and
cover (provenance `embedded`), with filename inference as fallback
(provenance `filename`) — parsing happens outside the write transaction,
covers are stored after it.

## Metadata (`LibrarianKit/Metadata`)

- **EpubParser**: ZIPFoundation → `META-INF/container.xml` → OPF. Dublin Core
  fields, calibre series metas, ISBN identifiers (UUID-guarded). Cover via
  EPUB3 `properties="cover-image"`, EPUB2 `<meta name="cover">`, or a
  manifest image named "cover"; hrefs are percent-decoded and normalized
  relative to the OPF directory.
- **PdfParser**: PDFKit document attributes (title, authors split on `;&,`,
  subject → description, creation year); cover = first page rendered through
  CoreGraphics into JPEG via ImageIO (no AppKit in the Kit).
- **MobiParser**: hand-rolled PalmDB reader ("BOOKMOBI"): full name from the
  MOBI header, EXTH records (100 author, 101 publisher, 103 description,
  104 ISBN, 106 date, 201 cover offset, 503 updated title, 524 language),
  cover = records[firstImageIndex + EXTH201] when it has an image magic.
  Malformed EXTH records (len < 8) end the walk cleanly.
- **MetadataExtractor** dispatches by format, never throws (parse failures
  become `parseErrorNote`), and drops junk titles ("Untitled") / unknown
  authors so the filename fallback stays visible.
- **CoverCache**: `book-<id>-grid.jpg` (≤600px) + `book-<id>-original.jpg` in
  Application Support/Librarian/Covers; size + clear exposed to Settings.

## Lookup (`LookupService`)

Query: ISBN if the book has one, else title + first author (filename
inference already happened at scan). Providers in settings order; per-provider
actor `RateLimiter` (min interval) and retry with exponential backoff on
429/5xx/URLError. Empty results = `noMatch` (≠ error).

`resolve(bookId:)`: top candidate auto-applies only when similarity ≥ 0.6 AND
(single candidate, clear margin ≥ 0.3, or ISBN query); otherwise
`needsConfirmation(candidates)` → picker. `apply(candidate:)` honors the
fill-empty/overwrite policy, skips manual-provenance fields, downloads the
cover outside the write transaction, and records provenance per changed
field. `resolveAll` runs sequentially, reports progress, and keeps going past
per-book failures (already-applied books persist → rerun = resume).

## Rename (`LibrarianKit/Rename`)

- **RenameTemplate**: parses tokens + one-level conditionals into nodes,
  validates unknown tokens, renders with missing-required tracking, then
  sanitizes (illegal chars, whitespace, dangling separators, "()", leading
  dots) and enforces the 255-byte cap (`trimToBytes`, char-boundary safe).
- **RenamePlanner**: per file → noOp / excluded(reason) / ready / collision.
  Claimed-name sets per directory seed lazily from disk minus batch members'
  current names; batch-internal and on-disk collisions get " (2)" suffixes
  computed stem-first so the counter survives the byte cap. Case-only renames
  are ready, never self-collisions.
- **RenameExecutor**: per row — runtime re-check of the target (stale plans
  re-suffix, never overwrite), `moveItem`, then one write transaction
  updating `bookFile.path` and inserting the `renameLog` row; if the DB write
  fails the file move is rolled back. Undo replays the latest non-reverted
  batch in reverse, restoring paths and setting `revertedFlag`.

## Export (`Exporters`)

- JSON via `JSONSerialization` (sorted keys, pretty): `schema_version: 1`,
  `book_count`, `books[]` with snake_case fields, provenance map, `files[]`
  (path/format/size_bytes/modified_date/missing). `includeCovers` copies
  originals to `covers/book-<id>.jpg` next to the output and sets relative
  `cover_path`.
- CSV: header + one row per book, CRLF, RFC 4180 quoting against the active
  delimiter, formats joined with `;`, multi-value fields with the configured
  separator, and a UTF-8 BOM prefix for Excel.

## App layer (`Sources/Librarian`)

`AppModel` (@MainActor ObservableObject) owns the Kit services and all view
state; `visibleEntries` applies search/filters/sort in memory. Scan progress
and completions hop to the main actor via Tasks. The candidate picker runs
inside batch resolution: the queue pauses at the ambiguous book and resumes
after Apply/Skip. Views are dumb; every mutation goes through AppModel →
Kit.
