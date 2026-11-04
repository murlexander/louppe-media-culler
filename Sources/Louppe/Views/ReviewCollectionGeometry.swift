import AppKit
import SwiftUI

/// Identity and source index are presentation inputs. Neither selection nor
/// current belongs here: mounted cell content observes its existing state owner.
struct ReviewCollectionEntry: Equatable {
    let id: String
    let index: Int
    let physicalFileIDs: [String]
}

struct ReviewCollectionSection: Equatable {
    let id: String
    let title: String?
    let entries: [ReviewCollectionEntry]
}

/// Built once per presentation generation, never for a current/selection change.
/// Indexed follow and handoff lookup do not enumerate intervening cells/groups.
final class ReviewCollectionProjection {
    let sections: [ReviewCollectionSection]
    let entries: [ReviewCollectionEntry]
    let sectionRanges: [Range<Int>]
    let sectionByPosition: [Int]
    let positionByID: [String: Int]
    let positionByPhysicalFileID: [String: Int]

    init(sections: [ReviewCollectionSection]) {
        self.sections = sections
        var entries: [ReviewCollectionEntry] = []
        var ranges: [Range<Int>] = []
        var sectionByPosition: [Int] = []
        var byID: [String: Int] = [:]
        var byPhysicalID: [String: Int] = [:]
        for (sectionIndex, section) in sections.enumerated() {
            let start = entries.count
            for entry in section.entries {
                let position = entries.count
                byID[entry.id] = position
                for id in entry.physicalFileIDs { byPhysicalID[id] = position }
                entries.append(entry)
                sectionByPosition.append(sectionIndex)
            }
            ranges.append(start..<entries.count)
        }
        self.entries = entries
        sectionRanges = ranges
        self.sectionByPosition = sectionByPosition
        positionByID = byID
        positionByPhysicalFileID = byPhysicalID
    }
}

/// SwiftUI may reevaluate an Equatable body after mounting with identical
/// inputs. Cache the actual immutable projection, rather than assuming a body
/// evaluation is a structural generation. Source equality borrows COW arrays.
@MainActor
final class ReviewCollectionProjectionCache<Source: Equatable> {
    private var source: Source?
    private var projection: ReviewCollectionProjection?

    func resolve(for source: Source, build: () -> ReviewCollectionProjection) -> ReviewCollectionProjection {
        if let projection, self.source == source { return projection }
        let result = build()
        self.source = source
        projection = result
        return result
    }
}

struct ReviewCollectionViewportReceipt: Equatable {
    let physicalFileID: String
    /// Signed distance from the viewport top to the actual media tile top.
    let topOffset: CGFloat
}

enum ReviewCollectionStyle: Equatable {
    case browser
    case grid(thumbnailSize: CGFloat)

    var spacing: CGFloat { self == .browser ? 6 : 10 }
    var topPadding: CGFloat { self == .browser ? 10 : 12 }
}

/// Only section geometry is retained. Item rectangles are constant-time integer
/// arithmetic; a viewport query binary-searches sections and visits visible rows.
struct ReviewCollectionGeometry {
    struct Section {
        let entryRange: Range<Int>
        let headerFrame: CGRect?
        let itemsTop: CGFloat
        let bottom: CGFloat
    }
    struct Element: Hashable {
        enum Key: Hashable { case item(Int), header(Int) }
        let key: Key
        let frame: CGRect

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.frame == rhs.frame }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    let sections: [Section]
    let columns: Int
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let horizontalOrigin: CGFloat
    let contentHeight: CGFloat
    let width: CGFloat
    let spacing: CGFloat
    let rightToLeft: Bool

    init(projection: ReviewCollectionProjection, style: ReviewCollectionStyle,
         width: CGFloat, captionHeight: CGFloat, headerHeight: CGFloat,
         rightToLeft: Bool) {
        self.width = max(1, width)
        self.rightToLeft = rightToLeft
        spacing = style.spacing
        let available: CGFloat
        switch style {
        case .browser:
            available = 102
            columns = 1
            itemWidth = 102
            itemHeight = 102
            horizontalOrigin = 10
        case .grid(let thumbnailSize):
            available = max(1, width - 18)
            columns = max(1, Int((available + spacing) / (max(1, thumbnailSize) + spacing)))
            itemWidth = min(thumbnailSize * 1.4, max(1, (available - CGFloat(columns - 1) * spacing) / CGFloat(columns)))
            itemHeight = itemWidth + 3 + captionHeight
            horizontalOrigin = (rightToLeft ? 6 : 12)
                + max(0, (available - CGFloat(columns) * itemWidth - CGFloat(columns - 1) * spacing) / 2)
        }
        var result: [Section] = []
        var y = style.topPadding
        for (index, section) in projection.sections.enumerated() {
            let range = projection.sectionRanges[index]
            let header: CGRect?
            if section.title != nil, !range.isEmpty {
                header = CGRect(x: style == .browser ? 10 : (rightToLeft ? 6 : 12), y: y,
                                width: available, height: headerHeight)
                y += headerHeight + spacing
            } else {
                header = nil
            }
            let top = y
            let rows = (range.count + columns - 1) / columns
            if rows > 0 { y += CGFloat(rows) * itemHeight + CGFloat(rows - 1) * spacing }
            result.append(Section(entryRange: range, headerFrame: header, itemsTop: top, bottom: y))
            if index + 1 < projection.sections.count, rows > 0 { y += spacing }
        }
        sections = result
        contentHeight = y + style.topPadding
    }

    func itemFrame(at position: Int, projection: ReviewCollectionProjection) -> CGRect? {
        guard projection.entries.indices.contains(position) else { return nil }
        let section = sections[projection.sectionByPosition[position]]
        let local = position - section.entryRange.lowerBound
        let column = local % columns
        let physicalColumn = rightToLeft ? columns - column - 1 : column
        return CGRect(x: horizontalOrigin + CGFloat(physicalColumn) * (itemWidth + spacing),
                      y: section.itemsTop + CGFloat(local / columns) * (itemHeight + spacing),
                      width: itemWidth, height: itemHeight)
    }

    func elements(in rect: CGRect, projection: ReviewCollectionProjection) -> [Element] {
        guard !sections.isEmpty else { return [] }
        var low = 0
        var high = sections.count
        while low < high {
            let mid = (low + high) / 2
            if sections[mid].bottom < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [Element] = []
        var sectionIndex = low
        while sectionIndex < sections.count {
            let section = sections[sectionIndex]
            if min(section.headerFrame?.minY ?? section.itemsTop, section.itemsTop) > rect.maxY { break }
            if let header = section.headerFrame, header.intersects(rect) {
                result.append(Element(key: .header(sectionIndex), frame: header))
            }
            let firstRow = max(0, Int(floor((rect.minY - section.itemsTop) / (itemHeight + spacing))))
            let lastRow = max(0, Int(floor((rect.maxY - section.itemsTop) / (itemHeight + spacing))))
            let start = min(section.entryRange.upperBound, section.entryRange.lowerBound + firstRow * columns)
            let end = min(section.entryRange.upperBound, section.entryRange.lowerBound + (lastRow + 1) * columns)
            if start < end {
                for position in start..<end {
                    if let frame = itemFrame(at: position, projection: projection), frame.intersects(rect) {
                        result.append(Element(key: .item(position), frame: frame))
                    }
                }
            }
            sectionIndex += 1
        }
        return result
    }
}

/// Share the exact caption/header shapes between native measurement and pixels.
struct ReviewGridCaption: View {
    let title: String
    var body: some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity)
    }
}

struct ReviewGroupHeader: View {
    let title: String
    let style: ReviewCollectionStyle
    var body: some View {
        HStack(spacing: style == .browser ? 6 : 8) {
            Text(title)
                .font(style == .browser ? .caption : .caption.weight(.semibold))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(title).layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            RoundedRectangle(cornerRadius: 1)
                .fill(.secondary.opacity(style == .browser ? 0.5 : 0.4)).frame(height: 2)
        }
        .padding(.horizontal, style == .browser ? 0 : 4)
        .padding(.vertical, style == .browser ? 3 : 4)
    }
}

/// Vertical placement of a fitted photo in its square slot (top-left origin).
/// Grid rests photos on their filename caption; the filmstrip centers them.
enum TileMediaAlignment: Sendable {
    case center
    case bottom
}

/// The photo and every tile adornment share this aspect-fit rectangle.
/// Unknown or nonvisual media keeps the original square slot.
enum TileMediaGeometry {
    static func fittedRect(in slot: CGRect, imageSize: CGSize?,
                           alignment: TileMediaAlignment = .center) -> CGRect {
        guard let imageSize, imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return slot }
        let scale = min(slot.width / imageSize.width, slot.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let y = alignment == .bottom ? slot.maxY - size.height : slot.midY - size.height / 2
        return CGRect(x: slot.midX - size.width / 2, y: y,
                      width: size.width, height: size.height)
    }

    static func imageSize(for item: PhotoItem, loadedImage: NSImage?) -> CGSize? {
        guard item.hasVisualPreview else { return nil }
        return item.videoDimensions ?? loadedImage?.size
    }
}

/// Accepts the unchanged square proposal, placing its single decorated photo
/// inside it without per-cell geometry readers or layout preferences.
struct TilePhotoLayout: Layout {
    let imageSize: CGSize?
    var alignment: TileMediaAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 102, height: 102))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rect = TileMediaGeometry.fittedRect(in: bounds, imageSize: imageSize, alignment: alignment)
        for subview in subviews {
            subview.place(at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center,
                          proposal: ProposedViewSize(rect.size))
        }
    }
}

/// Only mounted Grid cells report their displayed size. Retained thumbnail
/// pixels may outlive NSCache entries, so drag ownership must use these sizes.
@MainActor
final class GridTileImageSizes {
    var sizes: [PhotoContentRevision: CGSize] = [:]
}
