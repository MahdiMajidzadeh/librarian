import SwiftUI
import AppKit
import BookShelfKit

@MainActor
struct LibraryGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(model.displayedItems) { item in
                    BookGridCell(item: item)
                        .padding(6)
                        .background(
                            model.selection.contains(item.id)
                                ? AnyShapeStyle(.selection)
                                : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).onEnded {
                            if let file = item.files.first(where: { !$0.missingFlag }) {
                                model.openFile(file)
                            }
                        })
                        // One single-click handler for both plain and ⌘-click:
                        // two competing TapGestures used to fire together and
                        // wreck multi-selection.
                        .gesture(TapGesture(count: 1).onEnded {
                            if NSEvent.modifierFlags.contains(.command) {
                                if model.selection.contains(item.id) {
                                    model.selection.remove(item.id)
                                } else {
                                    model.selection.insert(item.id)
                                }
                            } else {
                                model.selection = [item.id]
                            }
                        })
                        .contextMenu {
                            if model.selection.count > 1, model.selection.contains(item.id) {
                                Button("Merge \(model.selection.count) Books into One") {
                                    Task { await model.mergeSelection() }
                                }
                            }
                            if item.files.count > 1 {
                                Button("Ungroup — One Book per File") {
                                    Task { await model.ungroup(bookId: item.id) }
                                }
                            }
                            Divider()
                            Button("Resolve Metadata Online") {
                                Task { await model.resolveMetadata(ids: [item.id]) }
                            }
                            if let file = item.files.first(where: { !$0.missingFlag }) {
                                Button("Reveal in Finder") {
                                    model.revealInFinder(file)
                                }
                            }
                        }
                }
            }
            .padding(16)
        }
        .onTapGesture { model.selection = [] }
    }
}

@MainActor
struct BookGridCell: View {
    let item: BookListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(path: item.book.coverCachePath, title: item.book.title)
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2, y: 1)
                .opacity(item.allFilesMissing ? 0.4 : 1)

            Text(item.book.title)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            if !item.book.authors.isEmpty {
                Text(item.book.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                FormatBadges(formats: item.formats)
                Spacer()
                StatusChips(item: item)
            }
        }
    }
}

/// Cover image loaded from the cache directory, with a lettered placeholder.
@MainActor
struct CoverView: View {
    let path: String?
    let title: String

    var body: some View {
        if let path, let image = CoverImageLoader.shared.image(atPath: path) {
            // The image lives in an overlay so its natural size can never push
            // the cell wider than the grid column (wide covers used to bleed
            // across neighboring cells). Jacket spreads and other wide images
            // anchor trailing, showing the front cover instead of the spine.
            let isWide = image.size.width > image.size.height * 1.15
            Rectangle()
                .fill(.clear)
                .overlay(alignment: isWide ? .trailing : .center) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
        } else {
            ZStack {
                Rectangle().fill(placeholderColor.gradient)
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 48, weight: .semibold, design: .serif))
                    // Lets the letter shrink when the view renders at thumbnail
                    // size (e.g. the 44×64 cover in CandidatePickerSheet).
                    .minimumScaleFactor(0.25)
                    .padding(4)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var placeholderColor: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .teal, .brown, .orange, .pink]
        var hash = 0
        for scalar in title.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0xFFFF
        }
        return palette[hash % palette.count]
    }
}

/// Small NSImage cache so grid scrolling doesn't hit disk repeatedly.
@MainActor
final class CoverImageLoader {
    static let shared = CoverImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    /// Cache keys include the mtime, so invalidation by bare path needs the
    /// last key each path was stored under.
    private var lastKeyByPath: [String: NSString] = [:]

    func image(atPath path: String) -> NSImage? {
        // Covers are rewritten in place (e.g. a better embedded cover replaces
        // a PDF render), so the cache key includes the file's mtime.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        let key = "\(path)|\(mtime)" as NSString
        if let stale = lastKeyByPath[path], stale != key {
            cache.removeObject(forKey: stale)
        }
        lastKeyByPath[path] = key
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Drops a stale entry after the cover file is rewritten in place.
    func invalidate(path: String) {
        if let key = lastKeyByPath.removeValue(forKey: path) {
            cache.removeObject(forKey: key)
        }
    }
}

@MainActor
struct FormatBadges: View {
    let formats: [BookFormat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(formats, id: \.self) { format in
                Text(format.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

@MainActor
struct StatusChips: View {
    let item: BookListItem

    var body: some View {
        HStack(spacing: 3) {
            if item.hasMissingFiles {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.orange)
                    .help("Some files are missing on disk")
            }
            if item.isAutoGrouped {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .help("Auto-grouped by filename — review if needed")
            }
            if item.book.metadataStatus == .unresolved {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.yellow)
                    .help(item.book.parseErrorNote ?? "Metadata unresolved")
            }
        }
        .font(.system(size: 10))
    }
}
