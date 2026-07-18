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
                        .simultaneousGesture(TapGesture(count: 1).modifiers(.command).onEnded {
                            if model.selection.contains(item.id) {
                                model.selection.remove(item.id)
                            } else {
                                model.selection.insert(item.id)
                            }
                        })
                        .gesture(TapGesture(count: 1).onEnded {
                            model.selection = [item.id]
                        })
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
                .lineLimit(2)
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
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(placeholderColor.gradient)
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 48, weight: .semibold, design: .serif))
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
final class CoverImageLoader {
    static let shared = CoverImageLoader()
    private let cache = NSCache<NSString, NSImage>()

    func image(atPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
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
