import SwiftUI
import AppKit

struct TextPreviewView: View {
    let item: PhotoItem
    @State private var state: LoadState = .loading
    @State private var retry = 0

    private enum LoadState {
        case loading
        case loaded(AttributedString)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let text):
                if text.characters.isEmpty {
                    ContentUnavailableView(L10n.text("Empty text file"), systemImage: "doc.text")
                } else {
                    NativeTextPreview(text: text, filename: item.displayName)
                        .frame(maxWidth: 820, maxHeight: .infinity)
                        .padding(.horizontal, 16)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label(L10n.text("Text preview unavailable"), systemImage: "doc.text")
                } description: {
                    Text(message)
                } actions: {
                    Button(L10n.text("Retry")) { retry += 1 }
                    Button(L10n.text("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.primaryURL])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .task(id: retry) {
            state = .loading
            do {
                try await Task.sleep(for: .milliseconds(40))
                let text = try await TextPreviewLoader.shared.load(item: item)
                try Task.checkCancellation()
                state = .loaded(text)
            } catch is CancellationError {
                // A departing document must never publish into its replacement.
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Native selection, copying, links and scrolling, with no editing surface.
struct NativeTextPreview: NSViewRepresentable {
    let text: AttributedString
    let filename: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 20, height: 28)
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Color.louppeAccent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.setAccessibilityLabel(filename)
        view.textStorage?.setAttributedString(Self.render(text))
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The enclosing view is keyed to contentRevision; rating changes don't
        // replace the text storage, selection, or scroll position.
    }

    static func render(_ text: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var seenListItems = Set<Int>()
        for run in text.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            if result.length > 0, block != previousBlock {
                result.append(NSAttributedString(string: "\n"))
            }
            previousBlock = block
            var size: CGFloat = 18
            var traits: NSFontTraitMask = []
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 12
            var prefix = ""
            for component in components {
                switch component.kind {
                case .header(let level):
                    size = CGFloat(max(20, 32 - level * 2))
                    traits.insert(.boldFontMask)
                case .blockQuote:
                    paragraph.headIndent = 18
                    paragraph.firstLineHeadIndent = 18
                    traits.insert(.italicFontMask)
                case .listItem(let ordinal):
                    paragraph.headIndent = 24
                    if seenListItems.insert(component.identity).inserted {
                        let ordered = components.contains { if case .orderedList = $0.kind { return true }; return false }
                        prefix = ordered ? "\(ordinal).  " : "•  "
                    }
                default: break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
            let base = NSFont(name: "NewYork-Regular", size: size)
                ?? NSFont(name: "Georgia", size: size)
                ?? NSFont.systemFont(ofSize: size)
            let font = NSFontManager.shared.convert(base, toHaveTrait: traits)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: prefix + String(text[run.range].characters), attributes: attributes))
        }
        return result
    }
}
