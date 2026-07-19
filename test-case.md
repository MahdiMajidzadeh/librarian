# Librarian — Test Case Catalog

**This file is the source of truth for the test suite.** Every automated test
in `Sources/BookShelfTests/` corresponds to exactly one case below, and every
case below must have a passing test.

## Sync workflow — mandatory

- **When this file changes** (a case is added, edited, or removed), the test
  code must be rewritten to match: add/update/delete the corresponding
  `runner.run("<Test name>")` block in the listed file, keep the test name in
  code identical to the *Test name* column, and re-run the suite until green.
- **When test code changes**, update this catalog in the same commit.
- Run with `swift run bookshelf-tests` (plain executable — **no XCTest**, no
  `.testTarget`; see CLAUDE.md toolchain rules). Fixtures are generated in
  code (`Fixtures.swift`) — never commit binary fixtures.
- New cases: pick the subsystem section, use the next free ID, and register
  new files in `main.swift` via `await xxxTests(runner)`.

Current suite size: **108 tests** — one per case below. FR/NFR numbers refer
to [requirements.md](requirements.md).

---

## Smoke (`main.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| SMOKE-01 | dependencies link and SQLite works | GRDB links, in-memory SQLite answers `SELECT 1`, Kit version constant. |

## Database (`DatabaseTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| DB-01 | migrations create all tables | Migrator (v1, v2…) creates `book`, `bookFile`, `provenance`, `rename_log`, `setting`. |
| DB-02 | book round-trips with JSON arrays and unicode | `authors`/`tags` JSON columns and Persian text survive a save/fetch cycle. |
| DB-03 | bookFile cascade-deletes with its book and enforces unique path | FK cascade + unique index on `path`. |
| DB-04 | provenance upserts per (book, field) | Re-saving a (book, field) pair replaces the source instead of duplicating. |
| DB-05 | settings store and delete | String KV `setting`/`setSetting`, nil deletes the row. |
| DB-06 | sort keys strip articles and invert author names | `Book.sortKey(forTitle:)` drops The/A/An; `sortKey(forAuthors:)` yields "last, first"; empty authors → nil. |
| DB-07 | recordProvenance upserts and replaces the source per (book, field) | The `AppDatabase.recordProvenance` convenience follows the same upsert semantics as DB-04. |
| DB-08 | contentKey is size\|mtime-seconds | `BookFile.contentKey` format, sub-second mtime jitter ignored, initializer derives the same key. |
| DB-09 | format catalog: extensions and embedded-metadata support | `BookFormat.allExtensions` covers all cases; `supportsEmbeddedMetadata` true only for epub/pdf/mobi/azw3. |
| DB-10 | repair junk embedded titles: re-derive from filename, keep manual and online | `AppDatabase.repairJunkEmbeddedTitles` (the v3 migration body) re-derives a junk embedded title from the filename, salvages the ISBN, drops the title provenance, leaves manual/real-embedded titles alone, and is idempotent. |

## Scanning (`ScannerTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| SCAN-01 | scan discovers nested files, skips hidden and unknown extensions | Recursive enumeration; hidden files, unknown extensions, and `ignoredExtensions` are skipped. |
| SCAN-02 | rescan with no changes touches nothing | Unchanged `contentKey` → 0 added/updated, no duplicate books (FR-1.4). |
| SCAN-03 | changed file is updated, not duplicated | Size/mtime change re-parses in place; row count stays 1. |
| SCAN-04 | deleted file is marked missing, rediscovered on return, purge removes it | `missingFlag` lifecycle: flag → clear on return → explicit purge deletes file + orphaned book (FR-1.5). |
| SCAN-05 | progress reports enumerating, processing, finished | `ScanProgress` phases and final counts. |
| SCAN-06 | default assigner: one book per filename stem when grouping is off | `LibraryScanner.defaultAssigner` fallback titles the book with the raw stem, method `single`. |
| SCAN-07 | folder access: persist/restore round-trip, nil when the folder vanishes | `FolderAccess` bookmark/path persistence; missing folder or empty DB → nil so the UI re-prompts (NFR-5, §9). |
| SCAN-08 | metadata status thresholds: complete needs title+author+year+cover | `ScanPipeline.status(for:)` table: complete / partial (any subset) / unresolved. |

## Grouping (`GroupingTests.swift`)

Regression pack (`groupingRegressionTests`):

| ID | Test name | Verifies |
|----|-----------|----------|
| GRP-01 | collection files sharing ' - 2007)' suffix never group | A shared year token must not glue different titles together. |
| GRP-02 | ungroup dissolves a book into manual per-file books that never re-join | `GroupingOperations.ungroup`: one manual book per file, invisible to the engine afterwards; single-file ungroup is a no-op. |
| GRP-03 | different works by one author never merge via authored filenames | "Author - Title" stems: shared author token isn't enough; swapped order of the same work still joins. |
| GRP-04 | volume numbers are significant; (n) copy markers are not | "Foundation 1"≠"Foundation 2"; "dune (1)" joins "dune". |
| GRP-05 | numeric and stopword-only title keys are not viable | `isViableTitleKey` / `meaningfulTokens` reject years, stopwords, bare numbers. |

Core pack (`groupingTests`):

| ID | Test name | Verifies |
|----|-----------|----------|
| GRP-06 | normalizer: casefold, diacritics, punctuation, noise words | `normalize`, `normalizeTitle`, `normalizeFilenameStem`, order-independent `authorTokenSet`. |
| GRP-07 | normalizer: ISBN validation | `extractISBN` accepts valid ISBN-10/13 with hyphens/urn prefix, rejects bad check digits. |
| GRP-08 | acceptance: dune.epub + Dune - Frank Herbert.pdf + dune_v2.mobi group as one | Spec acceptance case — three stem variants of one work group. |
| GRP-09 | same title, different authors stay separate (Rework case) | Author-token disagreement blocks a title-only match. |
| GRP-10 | Dune Messiah does not join Dune | Superset titles are distinct works. |
| GRP-11 | embedded ISBN outranks differing filenames | Rule 1 beats rule 3. |
| GRP-12 | embedded title+authors group across different stems | Rule 2 (metadata equality) joins unrelated filenames. |
| GRP-13 | manual split persists across rescans | `manualGroup = true` survives a rescan; engine never re-joins (FR-2.4). |
| GRP-14 | manual merge keeps target metadata and deletes empty sources | `GroupingOperations.merge` moves files, keeps target fields, removes drained books. |
| GRP-15 | filename inference: Author - Title orientation | `inferTitleAuthors` picks the right side as the title in both orders; plain stems → no author. |
| GRP-16 | token similarity: identical, partial, disjoint, empty | `Normalizer.tokenSimilarity` scoring bounds (drives lookup candidate scores). |
| GRP-17 | group method upgrades to a stronger rule, never downgrades | `groupMethod` rank single→metadata→isbn upgrades on join; a later filename join can't downgrade. |

## Epub parsing (`EpubParserTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| EPUB-01 | epub: full Dublin Core metadata extraction | Title, creators, publisher, language, ISBN, year, description, subjects. |
| EPUB-02 | epub: epub3 cover-image property extraction | Manifest `properties="cover-image"` cover. |
| EPUB-03 | epub: epub2 meta name=cover fallback | `<meta name="cover" content="…">` id-lookup path. |
| EPUB-04 | epub: unicode metadata (Persian) survives | RTL title/author round-trip, no transliteration (NFR-4). |
| EPUB-05 | epub: corrupt file throws ParseError, not crash | Non-zip data → `ParseError`. |
| EPUB-06 | cover cache: grid rendition capped at 600px, original kept | `CoverCache.store` writes both renditions; grid long edge ≤ 600 px. |

## PDF parsing (`PdfParserTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| PDF-01 | pdf: info dictionary metadata extraction | Title/Author/Keywords/CreationDate from the info dict. |
| PDF-02 | pdf: first page renders as cover jpeg | First-page render produces decodable JPEG cover data. |
| PDF-03 | pdf: author splitting variants | "A; B", "A and B", "A, B" split correctly. |
| PDF-04 | pdf: non-pdf throws ParseError | Garbage input → `ParseError`. |

## MOBI parsing (`MobiParserTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| MOBI-01 | mobi: EXTH metadata extraction | EXTH author/publisher/ISBN/date/description/subject records. |
| MOBI-02 | mobi: EXTH 503 updated title overrides full name | Updated-title record beats the PalmDB full name. |
| MOBI-03 | mobi: cover record extraction via EXTH 201 | Cover offset record resolves to image data. |
| MOBI-04 | mobi: no cover flag yields nil coverData | Absent cover flag → nil, no crash. |
| MOBI-05 | mobi: unicode author/title survive UTF-8 EXTH | UTF-8 text encoding honored. |
| MOBI-06 | mobi: garbage and truncated files throw, never crash | Bounds-checked reads on malformed input. |

## Metadata infrastructure (`MetadataTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| META-01 | embedded metadata: year parsed from date string variants | `year(fromDateString:)`: "1965", "1965-08-01", "August 1965"; rejects short/absent digits and implausible years. |
| META-02 | embedded metadata: isEmpty and populatedFields track every field | `isEmpty` flips on any field; `populatedFields` lists exactly the set fields (drives provenance). |
| META-03 | extractor dispatch: nil for non-embedded formats, failure for corrupt file | `MetadataExtractor.extract` → nil for cbz/txt, `.failure` (not crash) for corrupt epub. |
| META-04 | tag sanitizer: count capped at 15, over-length and duplicates dropped | `maxTagCount`/`maxTagLength` boundaries, trim + case-insensitive dedupe, `isValid`. |
| META-05 | cover cache: removeCover deletes both renditions, garbage data throws | `removeCover` clears grid + original (size returns to 0); non-image data throws `ParseError`. |
| META-06 | embedded metadata: junk filename and isbn titles detected, real titles kept | `isJunkTitle`: filename-shaped ("0071501126.pdf"), bare/hyphenated ISBN, authoring-tool artifacts, "untitled", punctuation-only → junk; real titles incl. "1984", "Catch-22", Persian pass. |
| META-07 | extractor: junk pdf title dropped, isbn salvaged from it | `MetadataExtractor.extract` nils a junk Title ("0071501126.pdf"), salvages the ISBN it contains into `meta.isbn`, leaves other fields and real titles untouched. |

## Online lookup (`LookupTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| LOOK-01 | open library: parses docs into scored candidates | Doc → candidate mapping incl. cover URL; exact title outscores near-miss. |
| LOOK-02 | isbn query hits isbn endpoint and scores 1.0 | ISBN routing and perfect-match scoring. |
| LOOK-03 | google books used only when key present | Provider stack respects the `googleBooksAPIKey` setting; https cover upgrade; description mapped. |
| LOOK-04 | retry with backoff on 429 then success | Transient status retries; second attempt succeeds. |
| LOOK-05 | ambiguity: close scores need the picker, clear winner does not | `unambiguousBest` thresholds (auto-apply ≥ 0.75, gap ≥ 0.2, floor) (FR-3.4). |
| LOOK-06 | apply: fillEmpty keeps existing, manual always wins | Field precedence under the default policy (FR-3.2). |
| LOOK-07 | apply: overwrite replaces embedded but not manual | Overwrite policy still never touches manual fields. |
| LOOK-08 | batch resolve checkpoints and resumes after failure | Per-book checkpointing in settings; failed books recorded; resume state round-trip (FR-3.6). |
| LOOK-09 | reviewCompleted routes complete books to the picker | Explicit re-resolve of `.complete` books queues the picker; background batches auto-apply. |
| LOOK-10 | query built from filename when book has no metadata | `LookupQuery.forBook` filename inference fallback. |
| LOOK-11 | transient errors retry, permanent ones do not; empty query skips network | `HTTPStatusError.isTransient` table (429/5xx vs 4xx); `LookupQuery.isEmpty`; empty query makes zero requests. |
| LOOK-12 | provider no-match is not turned into a later provider's error | Zero hits from one provider stays a no-match when a later provider fails; all-fail still throws. |
| LOOK-13 | apply: candidate cover is fetched, cached, and gets provenance | Cover URL fetched via transport, stored in `CoverCache`, provenance "cover" recorded, status recomputed. |
| LOOK-14 | google books: largest cover preferred, both ISBN types extracted | `imageLinks` preference (large > thumbnail, https upgrade); ISBN_10 + ISBN_13 extraction. |
| LOOK-15 | open library: docs without a title are dropped | Title-less docs are filtered from candidates. |

## Rename (`RenameTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| REN-01 | template: default renders author - title.ext | Default template output. |
| REN-02 | template: all tokens render | Every `{token}` resolves against a fully populated book. |
| REN-03 | template: conditional renders only when guard present | `{guard? …}` segments render iff the guard token has a value. |
| REN-04 | template: missing required token excludes with reason (FR-4.9) | Required token without a value → nil name + missing-token list. |
| REN-05 | template: empty collapse leaves no dangling separators | Collapsed tokens leave no orphan separators/brackets. |
| REN-06 | template: sanitization strips illegal chars and truncates UTF-8 safely | Path-illegal chars removed; 255-byte truncation on a character boundary (Persian-safe, NFR-4). |
| REN-07 | template: parse errors on unknown token and unbalanced braces | `ParseFailure` on bad syntax. |
| REN-08 | planner: multi-format book renames consistently, collisions suffixed | Same base name across a book's files; in-batch collisions get " (n)" (FR-4.5/4.6). |
| REN-09 | planner: collision with existing disk file gets (2) suffix | Disk collisions never overwrite. |
| REN-10 | planner: case-only rename is not a collision | Case-insensitive-filesystem self-match doesn't count as taken. |
| REN-11 | executor: renames, updates database, journals, and undoes fully | Move + DB path update per file, `rename_log` journal, full undo restores paths; second undo is a no-op (FR-4.7/4.8). |
| REN-12 | executor: excluded and no-op rows are skipped | Unchecked/no-op rows leave the disk untouched. |
| REN-13 | template: token value table (author_sort, series_index, authors, isbn) | `author_sort` re-capitalization, whole vs fractional `series_index`, `authors` join, isbn13-over-isbn10 preference. |
| REN-14 | planner: missing-on-disk files are excluded with their own status | `missingFlag` files → `.missingOnDisk`, excluded, no proposed name. |
| REN-15 | planner: collision suffix keeps the name within 255 bytes | Suffixing a name already at the APFS cap shortens the stem; extension survives. |

## Export (`ExportTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| EXP-01 | json export: schema v1, provenance, files, unicode round-trip | Stable schema, provenance map, per-file objects, Persian intact (FR-5.2). |
| EXP-02 | json export: covers folder with relative paths | `includeCovers` copies originals to `covers/` with relative `cover_path` (FR-5.4). |
| EXP-03 | csv export: BOM, delimiter, escaping, multi-value join | UTF-8 BOM for Excel, quote escaping, "; " multi-value join (FR-5.3, NFR-4). |
| EXP-04 | csv export: custom delimiter and separator honored | `Options` overrides. |
| EXP-05 | csv per-file mode: one row per file with repeated book columns | `Mode.perFile` shape and per-file columns. |
| EXP-06 | rename dry-run export: statuses, BOM, escaping | `RenamePlanExporter.exportCSV` basics. |
| EXP-07 | export scope: selection subset only | `ExportRecord.fetch(bookIds:)` subset. |
| EXP-08 | csv per-book: formats deduped, file_count counts every file | Duplicate formats collapse in `formats`; `file_count`/`total_size_bytes` still count all files. |
| EXP-09 | json export: grid rendition used when the original cover is gone | Cover export falls back from the original to the grid file. |
| EXP-10 | rename plan export: every status maps to its label | All five `RenamePlanItem.Status` values → documented label strings. |

## Folder watching (`FolderWatcherTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| WATCH-01 | folder watcher: debounced change fires once, stop silences | FSEvents burst collapses to ≈1 callback; `isWatching` reflects start/stop; no callbacks after `stop()` (FR-1.6). |

## End-to-end pipeline (`EndToEndTests.swift`)

| ID | Test name | Verifies |
|----|-----------|----------|
| E2E-01 | cover ranking: embedded epub cover replaces pdf page render | `coverRank`: epub/mobi embedded beats PDF render, never the reverse. |
| E2E-02 | tag sanitizer: prose keywords are dropped, keywords kept | Sanitizer behavior on realistic PDF keyword prose (still used for online-lookup categories). |
| E2E-03 | pipeline: embedded keywords never become tags, re-extract clears old ones | Embedded subjects are never applied as tags; re-extract clears embedded-sourced tags (and their provenance) from older rows; online and manual tags survive. |
| E2E-04 | rebuild auto-groups: splits mis-grouped files, keeps good groups and manual books | `rebuildGroups` summary; manual books untouched. |
| E2E-05 | re-extract upgrades covers on an already-scanned library | Re-extract swaps PDF covers for embedded ones in place. |
| E2E-06 | manual cover survives re-extract | Manual cover provenance blocks the upgrade path. |
| E2E-07 | e2e: scan groups Dune trio, parses Persian epub, exports valid JSON | Full pipeline: scan → parse → group → status → JSON export. |
| E2E-08 | pipeline: junk embedded title loses to filename, re-extract repairs old rows | Scan of a PDF with a junk Title keeps the filename-derived title (+ salvaged ISBN on the book); re-extract resets junk embedded titles from older rows and drops their provenance; manual titles survive. |

---

## Known coverage limits (accepted, not cases)

- **App target (`Sources/BookShelf/`)** — `AppModel.displayedItems`
  search/filter/sort, `BookListItem` derivations, and manual-edit parsing are
  pure logic but live in the SwiftUI target, which the test executable does
  not import. Testing them requires lifting them into BookShelfKit first.
- **`RenameExecutor` fault-recovery branches** (DB write fails after a
  successful move; undo move fails) need a fault-injecting FileManager.
- **`RateLimiter` pacing** is timing-sensitive; tests run with
  `minRequestInterval: .zero`.
- **Live network / `HTTP.live`** — never exercised; all lookup tests stub the
  transport (offline-first, NFR).
- **Security-scoped bookmarks** — the CLI test process has no sandbox
  entitlement; SCAN-07 exercises the plain-bookmark/raw-path fallback, which
  is the dev-build path.
