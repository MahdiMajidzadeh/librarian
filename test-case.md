# Librarian — Test-Case Catalog

**This file is the source of truth for the test suite.** Every case maps 1:1
to an XCTest method in `Tests/LibrarianKitTests/` — the *Test name* column is
the exact method name, in the file named by the *Suite* column. If this
catalog changes, the tests must be rewritten to match (and vice versa: any
test-code change must update this catalog in the same commit). Run with
`swift test`.

## Database — `DatabaseTests.swift`

| ID | Test name | Verifies |
|---|---|---|
| DB-01 | `testMigrationCreatesTables` | v1 migration creates book, bookFile, provenance, renameLog, setting tables |
| DB-02 | `testBookRoundTrip` | Insert/fetch preserves all fields incl. authors array and Persian text |
| DB-03 | `testBookFileCascadeDelete` | Deleting a book cascades to its files |
| DB-04 | `testProvenanceUpsert` | Saving provenance for the same (book, field) replaces the source |
| DB-05 | `testSettingsDefaults` | Unset key → built-in default; set/get round-trips; nil deletes |
| DB-06 | `testPurgeMissingFiles` | Purge removes missing file rows and now-orphaned books only |
| DB-07 | `testFetchLibraryGroupsFiles` | fetchLibrary pairs each book with exactly its files |
| DB-08 | `testSortKeyGeneration` | "The Title"→"title"; "Frank Herbert"→"herbert, frank"; single-word names pass through |
| DB-09 | `testRefreshMetadataStatus` | Status transitions: unresolved → partial (title+author) → complete (+year/ISBN) |

## Scanning — `ScannerTests.swift` (FR-1.x)

| ID | Test name | Verifies |
|---|---|---|
| SCAN-01 | `testInitialScanAddsFiles` | All supported files found recursively, one BookFile per disk file |
| SCAN-02 | `testScanSkipsHiddenFiles` | Dot-files are not scanned (FR-1.2) |
| SCAN-03 | `testScanSkipsIgnoredExtensions` | Extensions from the ignore-list setting are skipped |
| SCAN-04 | `testScanSkipsUnknownExtensions` | Unknown extensions (e.g. .xyz) are ignored (§4) |
| SCAN-05 | `testRescanUnchangedIsIncremental` | Second scan: all files unchanged, none re-parsed (FR-1.4) |
| SCAN-06 | `testRescanPreservesResolvedMetadata` | Manual title + provenance survive a rescan untouched (FR-1.4) |
| SCAN-07 | `testDeletedFileMarkedMissing` | File removed from disk → missingFlag, book kept (FR-1.5) |
| SCAN-08 | `testReappearedFileClearsMissing` | Restored file clears missingFlag |
| SCAN-09 | `testChangedFileReparsed` | Size/mtime change → re-parse updates the file's embedded keys |
| SCAN-10 | `testScanProgressReported` | Progress callbacks are monotonic and end at processed == total (FR-1.3) |
| SCAN-11 | `testRecursiveScan` | Files in nested subfolders are found (FR-1.2) |
| SCAN-12 | `testParseFailureNonFatal` | Corrupt epub → book exists with parseErrorNote, status unresolved (§9) |
| SCAN-13 | `testScanExtractsCover` | Epub cover lands in the cache; book.coverCachePath set (FR-3.5) |
| SCAN-14 | `testManualCoverSurvivesRescan` | A manually set cover is not replaced by a rescan |
| SCAN-15 | `testMergeDuringScanIsNotClobbered` | A merge committed while a scan is in flight survives reconciliation (grouping reads fresh tokens in-transaction) |
| SCAN-16 | `testUngroupDuringScanIsNotClobbered` | An ungroup committed mid-scan survives; files are not reassigned back together |

## Grouping — `GroupingTests.swift` (FR-2.x, §9)

| ID | Test name | Verifies |
|---|---|---|
| GRP-01 | `testNormalizerKey` | Case folding, diacritics stripped, punctuation removed |
| GRP-02 | `testStemKeyNoiseWords` | `._-` collapse; v2/final/(1)/ocr noise stripped (FR-2.1 rule 3) |
| GRP-03 | `testAuthorSetKeyOrderIndependent` | Author sets match regardless of order (§9) |
| GRP-04 | `testSimilarityScore` | Token-overlap similarity: identical=1, disjoint=0, partial in between |
| GRP-05 | `testGroupByISBN` | Identical embedded ISBN → one group, method isbn (rule 1) |
| GRP-06 | `testGroupByTitleAuthor` | Normalized (title, author) match → one group, method metadata (rule 2) |
| GRP-07 | `testGroupByFilenameStem` | Stem match → one group (rule 3) |
| GRP-08 | `testFilenameGroupMarkedAutoGrouped` | Any filename-only join → method filename ("auto-grouped", FR-2.5) |
| GRP-09 | `testSameTitleDifferentAuthorsStaySeparate` | Two "Rework"s with different embedded authors stay separate (§9) |
| GRP-10 | `testUnknownAuthorJoinsWhenNoConflict` | Files without author info join a stem group when authors don't conflict |
| GRP-11 | `testManualGroupOverridesAutomatic` | manualGroupId isolates a file from automatic stem matches (FR-2.4) |
| GRP-12 | `testManualSingletonNeverRegroups` | A solo manual token pins a file alone despite matching stems |
| GRP-13 | `testDuneAcceptanceCase` | dune.epub + "Dune - Frank Herbert.pdf" + dune_v2.mobi → one book, three formats (§6.2 acceptance) |
| GRP-14 | `testMergeCommand` | GroupCommands.merge: one surviving book, empty fields filled, shared token |
| GRP-15 | `testUngroupCommand` | Ungroup: one book per file, unique tokens, original keeps metadata |
| GRP-16 | `testMergeSurvivesRescan` | Merged book stays merged after a fresh scan (FR-2.4) |
| GRP-17 | `testCoverFromFileCommand` | setCover(fromFile:) extracts that file's cover, provenance manual |
| GRP-18 | `testJunkISBNDoesNotGroup` | Placeholder / checksum-invalid embedded ISBNs never act as grouping keys; valid ISBNs still do (§9) |
| GRP-19 | `testSplitSingleFileCommand` | split(fileId:) pulls one file out of a group into its own book (unique token, rest untouched), seeded with the file's embedded title/authors/cover; persists across rescans |
| GRP-20 | `testUngroupSeedsMetadataAndCovers` | Ungrouped books show their file's embedded title, authors, and cover with embedded provenance — not a bare filename guess |

## EPUB parser — `EpubParserTests.swift` (§6.3)

| ID | Test name | Verifies |
|---|---|---|
| EPUB-01 | `testParseDublinCore` | dc:title, multiple dc:creator, language, publisher, year from dc:date, description |
| EPUB-02 | `testParseISBNFromIdentifier` | dc:identifier with opf:scheme="ISBN" → isbn13 |
| EPUB-03 | `testIgnoreUUIDIdentifier` | UUID identifiers are not misread as ISBNs |
| EPUB-04 | `testParseCalibreSeries` | calibre:series + series_index meta tags |
| EPUB-05 | `testCoverByMetaReference` | EPUB 2 `<meta name="cover">` → manifest item → cover bytes |
| EPUB-06 | `testCoverByProperties` | EPUB 3 `properties="cover-image"` item |
| EPUB-07 | `testPercentEncodedCoverHref` | "cover%20image.jpg" href resolves to the real entry |
| EPUB-08 | `testNotAZipThrows` | Non-zip data → ParseError.notAZipArchive |
| EPUB-09 | `testMissingContainerThrows` | Zip without META-INF/container.xml → error |

## PDF parser — `PdfParserTests.swift` (§6.3)

| ID | Test name | Verifies |
|---|---|---|
| PDF-01 | `testParseInfoDictionary` | Title, author, creation-date year from the Info dictionary |
| PDF-02 | `testMultipleAuthorsSplit` | "A; B" / "A & B" author strings split into a list |
| PDF-03 | `testFirstPageCoverRender` | First page renders to JPEG cover data (fallback cover) |
| PDF-04 | `testUnreadableThrows` | Garbage bytes → ParseError.unreadable |

## MOBI parser — `MobiParserTests.swift` (§6.3)

| ID | Test name | Verifies |
|---|---|---|
| MOBI-01 | `testParseFullTitle` | Full name from the MOBI header name offset/length |
| MOBI-02 | `testParseEXTHFields` | EXTH author/publisher/description/ISBN/date/language records |
| MOBI-03 | `testParseCoverRecord` | EXTH 201 + first-image-index → embedded cover bytes |
| MOBI-04 | `testMalformedEXTHRecordStopsCleanly` | Record with length < 8 ends the walk without crashing (§9) |
| MOBI-05 | `testNotBookMobiThrows` | Non-BOOKMOBI data → ParseError.notPalmDatabase |
| MOBI-06 | `testUpdatedTitleOverridesHeaderTitle` | EXTH 503 updated title wins over the header name |

## Metadata common — `MetadataTests.swift`

| ID | Test name | Verifies |
|---|---|---|
| META-01 | `testJunkTitleDropped` | "Untitled"/"unknown" embedded titles are discarded |
| META-02 | `testUnknownAuthorDropped` | "Unknown" authors are discarded |
| META-03 | `testISBNNormalization` | Hyphens/urn:isbn: stripped; 10/13 digits accepted; others rejected |
| META-04 | `testParseYearFormats` | "2005-06-01", "June 2005", "2005" all → 2005; junk → nil |
| META-05 | `testFilenameInferenceAuthorTitle` | "Herbert - Dune" → author Herbert, title Dune (§6.3 acceptance) |
| META-06 | `testFilenameInferenceTitleAuthor` | "A Long Book Name - Frank Herbert" → title first when first part isn't name-like |
| META-07 | `testFilenameInferenceTitleOnly` | No separator → whole stem as title, no author |
| META-08 | `testExtractorDispatchUnsupportedFormat` | txt/fb2 → empty metadata, no parse error (§4 tier 2) |
| META-09 | `testCoverCacheStoreAndVariants` | store() writes grid (≤600px) + original variants (FR-3.5) |
| META-10 | `testCoverCacheClearAndSize` | totalSizeBytes > 0 after store; clear() empties the cache |

## Online lookup — `LookupTests.swift` (FR-3.x; stub providers, no network)

| ID | Test name | Verifies |
|---|---|---|
| LOOK-01 | `testGoogleBooksParse` | Canned volumes JSON → candidates with ISBNs, year, https cover URL |
| LOOK-02 | `testGoogleBooksSearchURLByISBN` | Query URL uses `isbn:` term when ISBN present |
| LOOK-03 | `testGoogleBooksSearchURLTitleAuthor` | `intitle:` + `inauthor:` terms otherwise |
| LOOK-04 | `testOpenLibraryParse` | Canned search JSON → candidates incl. cover id URL |
| LOOK-05 | `testOpenLibrarySearchURL` | title/author/limit/fields query items |
| LOOK-06 | `testQueryPrefersISBN` | Book with ISBN → ISBN query; without → title+author (§6.3) |
| LOOK-07 | `testProviderOrderSetting` | providerOrder setting flips which provider is asked first |
| LOOK-08 | `testFallbackToSecondProvider` | Empty first provider → second provider's candidates used |
| LOOK-09 | `testNoMatchDistinctFromError` | All-empty → noMatch; provider throwing → failed (FR-3.6) |
| LOOK-10 | `testAutoApplyConfidentMatch` | Single high-similarity candidate auto-applies with provenance |
| LOOK-11 | `testAmbiguousNeedsConfirmation` | Two close candidates → needsConfirmation (FR-3.4) |
| LOOK-12 | `testLowSimilarityNeedsConfirmation` | Low-similarity single candidate → picker, not silent apply |
| LOOK-13 | `testFillEmptyPolicy` | fill_empty: existing fields kept, empty ones filled (FR-3.2) |
| LOOK-14 | `testOverwritePolicy` | overwrite: online values replace embedded ones (FR-3.2) |
| LOOK-15 | `testManualFieldsNeverOverwritten` | Fields with manual provenance untouched under both policies |
| LOOK-16 | `testRetryWithBackoffOnTransientError` | 500-twice-then-succeed stub resolves after retries (FR-3.6) |
| LOOK-17 | `testRateLimiterSpacesRequests` | Two waitTurn() calls are ≥ minInterval apart (FR-3.6) |
| LOOK-18 | `testBatchResolveContinuesAfterFailure` | resolveAll: one failing book doesn't stop the rest (resumable) |

## Rename — `RenameTests.swift` (FR-4.x)

| ID | Test name | Verifies |
|---|---|---|
| REN-01 | `testRenderBasicTemplate` | `{author} - {title}.{ext}` renders from book fields |
| REN-02 | `testConditionalSeriesSegment` | `{series? …}` renders with series, collapses cleanly without (FR-4.2) |
| REN-03 | `testMissingRequiredTokenReported` | Unconditional token without value → listed in missingRequiredTokens |
| REN-04 | `testSanitizeIllegalCharacters` | `/` and `:` replaced; control chars stripped (FR-4.4) |
| REN-05 | `testEmptyTokenCollapse` | No dangling " - " or "()" when optional data is absent |
| REN-06 | `testUnicodePreserved` | Persian title kept verbatim — no transliteration (FR-4.4, NFR-4) |
| REN-07 | `test255ByteCap` | Long UTF-8 name truncated to ≤255 bytes on a char boundary, ext kept |
| REN-08 | `testUnknownTokenValidationError` | `{bogus}` → template validation error |
| REN-09 | `testPlanNoOpDetection` | Already-conforming file → noOp row, excluded from batch |
| REN-10 | `testPlanCollisionSuffix` | Existing on-disk target → " (2)" suffix, row flagged collision (FR-4.5) |
| REN-11 | `testPlanBatchInternalCollision` | Two batch rows rendering identically → second suffixed |
| REN-12 | `testPlanExcludesMissingToken` | Template needs {author}, author unknown → excluded + reason (FR-4.9) |
| REN-13 | `testPlanExcludesMissingFile` | missingFlag file → excluded row |
| REN-14 | `testPlanCaseOnlyRename` | Case-only change → ready (not a self-collision) |
| REN-15 | `testSuffixRespects255Bytes` | Suffixing a max-length name keeps the counter and the cap |
| REN-16 | `testExecuteRenames` | Files moved on disk, DB paths updated, journal rows written (FR-4.7) |
| REN-17 | `testExecuteNeverOverwrites` | Target created after planning → runtime re-suffix, no overwrite |
| REN-18 | `testUndoLastBatch` | Undo restores names + DB paths; entries marked reverted (FR-4.8) |
| REN-19 | `testUndoSurvivesRestart` | A fresh executor on the same DB still undoes the last batch |
| REN-20 | `testMultiFormatConsistentRename` | A 3-file book renames all files in one batch (FR-4.6) |

## Export — `ExportTests.swift` (FR-5.x)

| ID | Test name | Verifies |
|---|---|---|
| EXP-01 | `testJSONSchema` | schema_version 1, book fields, nested files[] with path/format/size/date/missing |
| EXP-02 | `testJSONProvenanceIncluded` | Per-field provenance map with source + fetched_at (FR-3.3) |
| EXP-03 | `testJSONCoversFolder` | includeCovers → covers/ folder + relative cover_path (FR-5.4) |
| EXP-04 | `testCSVHeaderAndRow` | Header row + one row per book with formats "epub;pdf" |
| EXP-05 | `testCSVBOMAndPersian` | Output starts with UTF-8 BOM; Persian text round-trips (FR-5.3) |
| EXP-06 | `testCSVEscaping` | RFC 4180: delimiter/quote/newline fields quoted, quotes doubled |
| EXP-07 | `testCSVDelimiterOptions` | Semicolon and tab delimiters honored (§6.7) |
| EXP-08 | `testCSVMultiValueSeparator` | Multiple authors joined with the configured separator |

## Folder watching — `FolderWatcherTests.swift` (FR-1.6)

| ID | Test name | Verifies |
|---|---|---|
| WATCH-01 | `testDetectsNewFile` | New file in the watched folder fires the callback |
| WATCH-02 | `testDebounceCoalesces` | A burst of writes produces one (coalesced) callback |
| WATCH-03 | `testStopPreventsCallbacks` | After stop(), changes fire nothing |

## End-to-end — `EndToEndTests.swift`

| ID | Test name | Verifies |
|---|---|---|
| E2E-01 | `testSeedScanRenameExportRoundTrip` | Seeded demo library: scan → groups/covers correct → rename with preview plan → undo restores → JSON+CSV exports validate; no-change rescan is all-unchanged and < 3 s (§6.1 acceptance) |
| E2E-02 | `testRescanAfterExternalRename` | File renamed outside the app → old row missing, new file joins the same logical book by stem |
| E2E-03 | `testMergeUngroupPersistAcrossRescan` | Manual merge then ungroup decisions survive subsequent rescans (FR-2.4) |
