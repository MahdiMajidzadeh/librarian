# Librarian

A native macOS app that catalogs your ebook folder **in place** — no files
moved, no managed library, no lock-in. Point it at the folder you already
have; it turns file soup into a browsable shelf.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)

## What it does

- **Scan in place** — recursive, incremental (2,000+ files in seconds; a
  no-change rescan is instant). Deleted files are marked missing, never
  silently dropped.
- **One book, many formats** — `dune.epub`, `Dune - Frank Herbert.pdf` and
  `dune_v2.mobi` become one entry with `EPUB · PDF · MOBI` badges. Grouping
  uses embedded ISBN, then title+author, then filename similarity — with a
  review indicator when only the filename matched. Merge or ungroup manually;
  your decisions stick.
- **Metadata & covers** — embedded metadata parsed from EPUB (OPF), PDF
  (Info + first-page cover), MOBI/AZW3 (EXTH). Optional online enrichment via
  Google Books and Open Library — explicit only, with a side-by-side
  picker (your file vs. the online match) when it's ambiguous. Every field
  shows where it came from; your manual edits always win.
- **Safe renaming** — template-driven (`{author} - {title} ({year}).{ext}`,
  conditional segments, Unicode-safe, APFS 255-byte aware). Mandatory
  preview with per-file checkboxes, collision-proof suffixing, and one-click
  undo of the last batch — even after a restart.
- **Export** — versioned JSON (with provenance, file lists, optional cover
  folder) and Excel-friendly CSV (UTF-8 BOM; Persian/RTL titles render
  correctly).

## Install & run

```bash
Scripts/make-app.sh     # builds Librarian.app in the repo root
open Librarian.app
```

Requires macOS 14+. The app is unsigned — right-click → Open the first time.

## Development

```bash
swift build                       # debug build
swift test                        # 126 tests, fully offline
swift run librarian-seed ~/tmp/demo-library   # sample library to play with
```

- Spec: [requirements.md](requirements.md)
- Living docs: [_contexts/](_contexts/README.md)
- Test catalog: [test-case.md](test-case.md)

## Privacy

No telemetry. The only network requests are to Google Books / Open Library,
and only when you explicitly ask for metadata.
