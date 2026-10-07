import SwiftUI

/// One truthful empty-session presentation shared by Gallery and Grid.
struct SessionEmptyView: View {
    let reason: SessionEmptyReason?
    let canUndo: Bool

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
    }

    private var title: String {
        switch reason {
        case .trashedUndoable:
            return L10n.text("Everything is in the Trash")
        case .movedOut:
            return L10n.text("Everything was moved")
        case .unavailableAfterFailedRestore:
            return L10n.text("No media could be restored")
        case nil:
            return L10n.text("No media left in this session")
        }
    }

    private var systemImage: String {
        switch reason {
        case .trashedUndoable:
            return "trash"
        case .movedOut:
            return "folder"
        case .unavailableAfterFailedRestore:
            return "exclamationmark.triangle"
        case nil:
            return "photo.on.rectangle.angled"
        }
    }

    private var message: String {
        switch reason {
        case .trashedUndoable where canUndo:
            return L10n.text("Undo Clean Up with ⌘Z before closing this session, while the files remain in Trash.")
        case .trashedUndoable:
            return L10n.text("The items were moved to the Trash.")
        case .movedOut:
            return L10n.text("Originals are intact at the destination. Move exports cannot be undone.")
        case .unavailableAfterFailedRestore:
            return L10n.text("Files may have left the Trash. Check the source folder and Trash before continuing.")
        case nil:
            return L10n.text("Open or scan the folder again to refresh this session.")
        }
    }
}
