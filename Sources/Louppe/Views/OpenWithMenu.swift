import SwiftUI

/// File → Open With, tile context menus and the Gallery photo's context menu.
/// Building or browsing it opens nothing; only choosing a row does.
struct OpenWithMenu: View {
    @ObservedObject var store: SessionStore
    let origin: OriginalFilesOrigin

    var body: some View {
        Menu(L10n.text("Open With")) {
            OpenWithMenuItems(store: store, origin: origin)
        }
        .disabled(!store.canHandOffOriginals(origin))
    }
}

struct OpenWithMenuItems: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var catalog = PhotoEditorCatalog.shared
    let origin: OriginalFilesOrigin

    var body: some View {
        // A lookup older than the catalog's interval refreshes off-main.
        let _ = catalog.refreshIfStale()
        ForEach(catalog.editors) { editor in
            Button {
                OriginalFilesOpener.open(origin, with: .editor(editor), store: store)
            } label: {
                Label {
                    Text(editor.title)
                } icon: {
                    Image(nsImage: catalog.icon(for: editor))
                }
            }
        }
        if !catalog.editors.isEmpty { Divider() }
        Button(L10n.text("Default App")) {
            OriginalFilesOpener.open(origin, with: .defaultApplication, store: store)
        }
    }
}
